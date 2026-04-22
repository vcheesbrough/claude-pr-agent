#!/usr/bin/env bash
# PR review orchestration entrypoint.
#
# Runs inside the pr-reviewer container. Expects the Woodpecker workspace
# mounted at CI_WORKSPACE with the PR branch checked out.
#
# Env (from Woodpecker secrets and built-ins):
#   CLAUDE_CODE_OAUTH_TOKEN    Claude.ai subscription OAuth token (required)
#   PR_REVIEWER_GH_APP_ID
#   PR_REVIEWER_GH_APP_INSTALLATION_ID
#   PR_REVIEWER_GH_APP_PRIVATE_KEY_B64
#   CI_REPO                    e.g. vcheesbrough/mini-config
#   CI_COMMIT_PULL_REQUEST     PR number
#   CI_COMMIT_TARGET_BRANCH    e.g. master
#   CI_WORKSPACE               Woodpecker workspace path
#
# Optional:
#   ANTHROPIC_API_KEY          API key (takes precedence over CLAUDE_CODE_OAUTH_TOKEN if set)
#   REVIEWER_DRY_RUN=1         print the review JSON to stdout instead of posting
#   MAX_DIFF_BYTES             hard cap on diff size (default 200000)
#   MAX_FILE_BYTES             hard cap on total injected file content (default 300000)

set -euo pipefail

log() { printf '[review] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Claude Code refuses --dangerously-skip-permissions as root.
# Woodpecker overrides the Dockerfile USER, so we drop privileges here.
if [[ "$(id -u)" -eq 0 ]]; then
  log "running as root — dropping to reviewer via gosu"
  exec gosu reviewer "$0" "$@"
fi

: "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN is required}"
: "${CI_REPO:?CI_REPO is required}"
: "${CI_COMMIT_PULL_REQUEST:?CI_COMMIT_PULL_REQUEST is required}"
: "${CI_COMMIT_TARGET_BRANCH:=master}"
: "${CI_WORKSPACE:?CI_WORKSPACE is required}"

log "workspace: $CI_WORKSPACE"
cd "$CI_WORKSPACE"
git config --global --add safe.directory "$CI_WORKSPACE"

log "minting GitHub App installation token"
GH_TOKEN=$(mint-github-token) || die "could not mint GitHub token"
export GH_TOKEN

log "fetching PR diff via GitHub API"
DIFF=$(curl -sf \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github.v3.diff" \
  "https://api.github.com/repos/${CI_REPO}/pulls/${CI_COMMIT_PULL_REQUEST}")
DIFF_LINES=$(printf '%s\n' "$DIFF" | wc -l)
log "diff is $DIFF_LINES lines"

if [[ -z "$DIFF" ]]; then
  log "empty diff — nothing to review"
  exit 0
fi

# Hard cap to avoid runaway token usage on huge refactors.
MAX_DIFF_BYTES=${MAX_DIFF_BYTES:-200000}
if (( ${#DIFF} > MAX_DIFF_BYTES )); then
  log "diff exceeds ${MAX_DIFF_BYTES} bytes — truncating"
  DIFF="${DIFF:0:$MAX_DIFF_BYTES}

[... diff truncated at ${MAX_DIFF_BYTES} bytes ...]"
fi

# Fetch full content of files changed in this PR and inject into the prompt.
# This eliminates the need for Claude to use Read/Grep/Glob tool calls.
PR_HEAD_SHA=$(git rev-parse HEAD)
PR_FILES=$(curl -sf \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${CI_REPO}/pulls/${CI_COMMIT_PULL_REQUEST}/files?per_page=100") \
  || PR_FILES="[]"
CHANGED_FILES=$(printf '%s\n' "$PR_FILES" | jq -r '.[] | select(.status != "removed") | .filename')
log "changed files: $(printf '%s\n' "$CHANGED_FILES" | grep -c .) non-removed"

MAX_FILE_BYTES=${MAX_FILE_BYTES:-300000}
INJECTED_FILES=""
INJECTED_BYTES=0

while IFS= read -r FILE_PATH; do
  [[ -z "$FILE_PATH" ]] && continue
  RAW=$(curl -sf \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${CI_REPO}/contents/${FILE_PATH}?ref=${PR_HEAD_SHA}" \
    | jq -r '.content // empty' \
    | base64 -d 2>/dev/null) || { log "could not fetch ${FILE_PATH} — skipping"; continue; }
  FILE_BYTES=${#RAW}
  if (( INJECTED_BYTES + FILE_BYTES > MAX_FILE_BYTES )); then
    log "file content cap reached (${INJECTED_BYTES} bytes) — omitting ${FILE_PATH} and remainder"
    INJECTED_FILES+=$'\n'"[... further files omitted — ${MAX_FILE_BYTES}-byte cap reached ...]"
    break
  fi
  INJECTED_FILES+=$'\n\n### `'"${FILE_PATH}"'`\n\n```\n'"${RAW}"$'\n```'
  INJECTED_BYTES=$(( INJECTED_BYTES + FILE_BYTES ))
  log "injected ${FILE_PATH} (${FILE_BYTES} bytes, running total ${INJECTED_BYTES})"
done <<< "$CHANGED_FILES"

log "total injected file content: ${INJECTED_BYTES} bytes"

CLAUDE_MD=""
if [[ -f CLAUDE.md ]]; then
  CLAUDE_MD=$(cat CLAUDE.md)
fi

SYSTEM_PROMPT_FILE=/etc/pr-reviewer/system-prompt.md
if [[ -f "$CI_WORKSPACE/.woodpecker/pr-review-prompt.md" ]]; then
  log "using repo-local system prompt from .woodpecker/pr-review-prompt.md"
  SYSTEM_PROMPT_FILE="$CI_WORKSPACE/.woodpecker/pr-review-prompt.md"
fi

PROMPT_FILE=$(mktemp)
REVIEW_JSON=$(mktemp)
trap 'rm -f "$PROMPT_FILE" "$REVIEW_JSON"' EXIT

{
  cat "$SYSTEM_PROMPT_FILE"
  printf '\n\n---\n\n# Project CLAUDE.md\n\n%s\n' "$CLAUDE_MD"
  printf '\n---\n\n# PR metadata\n\n'
  printf -- '- Repo: %s\n' "$CI_REPO"
  printf -- '- PR:   #%s\n' "$CI_COMMIT_PULL_REQUEST"
  printf -- '- Base: %s\n' "$CI_COMMIT_TARGET_BRANCH"
  printf '\n---\n\n# Diff\n\n```diff\n%s\n```\n' "$DIFF"
  if [[ -n "$INJECTED_FILES" ]]; then
    printf '\n---\n\n# Full contents of changed files (HEAD)\n\nProvided so you do not need to use any tools.\n%s\n' "$INJECTED_FILES"
  fi
} > "$PROMPT_FILE"

log "running as user: $(id)"
log "claude path: $(which claude 2>/dev/null || echo NOT FOUND)"
log "claude version: $(claude --version 2>&1 || echo FAILED)"
log "prompt file size: $(wc -c < "$PROMPT_FILE") bytes"

# CLAUDE_TIMEOUT can be set in the Woodpecker step environment to override
# the default. Large PRs (>200KB injected) routinely need more than 90s.
CLAUDE_TIMEOUT=${CLAUDE_TIMEOUT:-300}
log "running claude (timeout ${CLAUDE_TIMEOUT}s, model: sonnet, single-turn)"
set +e
timeout "${CLAUDE_TIMEOUT}s" claude \
  --print \
  --model claude-sonnet-4-6 \
  --allowed-tools "" \
  --output-format text \
  --dangerously-skip-permissions \
  < "$PROMPT_FILE" \
  > "$REVIEW_JSON" 2> >(tee /tmp/review.err >&2)
CLAUDE_RC=$?
set -e

log "claude rc=$CLAUDE_RC stdout=$(wc -c < "$REVIEW_JSON") bytes stderr=$(wc -c < /tmp/review.err) bytes"

if [[ $CLAUDE_RC -ne 0 ]] || [[ ! -s "$REVIEW_JSON" ]]; then
  log "claude failed (rc=$CLAUDE_RC) or produced empty output"
  log "stdout (first 500):"
  head -c 500 "$REVIEW_JSON" >&2 || true
  FAILURE_BODY=$(printf ':warning: **PR review agent failed** — see Woodpecker CI logs for details.\n\nExit code: `%s`' "$CLAUDE_RC")
  if [[ "${REVIEWER_DRY_RUN:-0}" == "1" ]]; then
    printf '%s\n' "$FAILURE_BODY"
  else
    gh pr comment "$CI_COMMIT_PULL_REQUEST" --repo "$CI_REPO" --body "$FAILURE_BODY" || true
  fi
  exit 1
fi

log "review generated ($(wc -c <"$REVIEW_JSON") bytes)"

if [[ "${REVIEWER_DRY_RUN:-0}" == "1" ]]; then
  log "DRY RUN — printing JSON to stdout instead of posting"
  printf '\n===== REVIEW JSON =====\n'
  cat "$REVIEW_JSON"
  printf '\n===== END =====\n'
  exit 0
fi

# Extract the JSON object from Claude's output.
# raw_decode finds the first '{' and parses exactly one JSON object from there,
# ignoring any leading prose, markdown fences, or trailing text.
log "extracting review JSON"
if ! python3 - "$REVIEW_JSON" <<'PYEOF' > /tmp/review_clean.json 2>/dev/null
import json, sys
text = open(sys.argv[1]).read()
s = text.find('{')
if s < 0:
    sys.exit(1)
obj, _ = json.JSONDecoder().raw_decode(text[s:])
print(json.dumps(obj))
PYEOF
then
  log "claude produced invalid JSON — dumping raw output and falling back to top-level comment"
  cat "$REVIEW_JSON"
  gh pr comment "$CI_COMMIT_PULL_REQUEST" --repo "$CI_REPO" --body-file "$REVIEW_JSON" || true
  exit 1
fi
mv /tmp/review_clean.json "$REVIEW_JSON"

VERDICT=$(jq -r '.verdict' "$REVIEW_JSON")
EVENT=$(jq -r '.event' "$REVIEW_JSON")
BODY=$(jq -r '.body' "$REVIEW_JSON")
COMMENT_COUNT=$(jq '.comments | length' "$REVIEW_JSON")
log "verdict: $VERDICT | event: $EVENT | inline comments: $COMMENT_COUNT"

# Build the GitHub review API payload
REVIEW_PAYLOAD=$(jq -n \
  --argjson review "$(cat "$REVIEW_JSON")" \
  '{
    body:     $review.body,
    event:    $review.event,
    comments: ($review.comments // [] | map({
      path: .path,
      line: .line,
      side: "RIGHT",
      body: .body
    }))
  }')

log "posting PR review to $CI_REPO#$CI_COMMIT_PULL_REQUEST"
HTTP_STATUS=$(curl -s -o /tmp/review-response.json -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${CI_REPO}/pulls/${CI_COMMIT_PULL_REQUEST}/reviews" \
  -d "$REVIEW_PAYLOAD")

if [[ "$HTTP_STATUS" == "200" ]]; then
  log "review posted successfully"
else
  log "review API returned $HTTP_STATUS — falling back to top-level comment"
  log "response: $(cat /tmp/review-response.json)"
  # Fall back: post the body as a plain comment
  gh pr comment "$CI_COMMIT_PULL_REQUEST" --repo "$CI_REPO" \
    --body "**$VERDICT**

$BODY

_(inline comments could not be posted — GitHub returned HTTP $HTTP_STATUS)_" || true
fi

log "done"
