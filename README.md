# pr-reviewer

Automated PR review agent. Runs Claude Code CLI headless inside a container
to review PR diffs against the repo's conventions (see `CLAUDE.md`) and post
a review comment to the GitHub PR.

Triggered by Woodpecker CI via `.woodpecker/pr-review-pipeline.yml` on every
`pull_request` event.

## Files

- `Dockerfile` — image definition (node:22-slim + Claude Code CLI + `gh` + Python helpers)
- `mint-github-token.py` — mints a short-lived GitHub App installation token
- `review.sh` — orchestration entrypoint (mint token, compute diff, run Claude, post comment)
- `system-prompt.md` — the review rules (iterate freely, no image rebuild required only if mounted)

## Auth model

Authenticates to GitHub as a **GitHub App** (`mini-config-pr-reviewer`), not
via a PAT. Installation tokens are minted at runtime from the App's private
key and last ~10 minutes.

App permissions: Pull requests (RW), Contents (R), Metadata (R).
Installed on: `vcheesbrough/mini-config`.

## Build and publish

```bash
# On mini, from the repo root
TAG=$(git rev-parse --short HEAD)
docker build -t registry.desync.link/pr-reviewer:$TAG devops-stack/pr-reviewer/
docker push registry.desync.link/pr-reviewer:$TAG

# Capture the pushed digest and pin it in .woodpecker/pr-review-pipeline.yml
docker inspect --format='{{index .RepoDigests 0}}' registry.desync.link/pr-reviewer:$TAG
```

Then update `.woodpecker/pr-review-pipeline.yml` with the new tag + digest and commit.

### Pinning the base image

On first build, capture the `node:22-slim` digest and pin it in the
`Dockerfile`:

```bash
docker pull node:22-slim
docker inspect --format='{{index .RepoDigests 0}}' node:22-slim
# e.g. node@sha256:abc123...
```

Replace `FROM node:22-slim` with `FROM node:22-slim@sha256:abc123...`.

## Secrets

Woodpecker repo-level secrets (seed via Woodpecker UI, **marked as
pull_request-allowed**):

- `anthropic_api_key`
- `pr_reviewer_gh_app_id`
- `pr_reviewer_gh_app_installation_id`
- `pr_reviewer_gh_app_private_key_b64` — base64-encoded PEM

The same four entries live in `secrets.env.enc` as the source of truth.
After a Woodpecker rebuild, re-seed the Woodpecker secrets from there.

## Local dry run

To test on mini without triggering Woodpecker:

```bash
cd /srv/dev/mini-config
docker run --rm -it \
  -v "$PWD:/workspace" \
  -e ANTHROPIC_API_KEY="$(sops -d --extract '["ANTHROPIC_API_KEY"]' secrets.env.enc)" \
  -e PR_REVIEWER_GH_APP_ID="$(sops -d --extract '["PR_REVIEWER_GH_APP_ID"]' secrets.env.enc)" \
  -e PR_REVIEWER_GH_APP_INSTALLATION_ID="$(sops -d --extract '["PR_REVIEWER_GH_APP_INSTALLATION_ID"]' secrets.env.enc)" \
  -e PR_REVIEWER_GH_APP_PRIVATE_KEY_B64="$(sops -d --extract '["PR_REVIEWER_GH_APP_PRIVATE_KEY_B64"]' secrets.env.enc)" \
  -e CI_REPO=vcheesbrough/mini-config \
  -e CI_COMMIT_PULL_REQUEST=1 \
  -e CI_COMMIT_TARGET_BRANCH=master \
  -e REVIEWER_DRY_RUN=1 \
  registry.desync.link/pr-reviewer:$TAG
```

`REVIEWER_DRY_RUN=1` prints the review to stdout instead of posting it.

## Disabling the reviewer quickly

If it goes rogue:

1. Rename `.woodpecker/pr-review-pipeline.yml` → `.woodpecker/pr-review-pipeline.yml.disabled` and push
2. Or delete any of the four Woodpecker secrets — the pipeline will fail fast

## Uncertainties / known risks

- `claude -p` headless mode is under-documented. If brittle, fallback is to
  rewrite `review.sh` as a small Python script using the Claude Agent SDK.
- Claude Code writes session state to `$HOME/.claude`; we set `HOME=/tmp` in
  the Dockerfile to keep it ephemeral.
- GitHub App tokens expire in 10 minutes — keep the pipeline fast.
