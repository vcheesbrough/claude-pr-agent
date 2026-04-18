# PR Review Agent — runs Claude Code CLI headless against a PR diff



FROM node:22-slim@sha256:f3a68cf41a855d227d1b0ab832bed9749469ef38cf4f58182fb8c893bc462383

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl python3 python3-pip jq gosu \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Pin the Claude Code CLI version — bump deliberately, never floating.
RUN npm install -g @anthropic-ai/claude-code@2.1.107

RUN pip3 install --break-system-packages --no-cache-dir \
      PyJWT==2.9.0 cryptography==43.0.1 requests==2.32.3

COPY mint-github-token.py /usr/local/bin/mint-github-token
COPY review.sh            /usr/local/bin/review
COPY system-prompt.md     /etc/pr-reviewer/system-prompt.md
RUN chmod +x /usr/local/bin/mint-github-token /usr/local/bin/review

# Claude Code refuses --dangerously-skip-permissions as root.
RUN useradd -m -s /bin/bash reviewer
USER reviewer

# Claude Code writes session state under $HOME/.claude — keep it ephemeral.
ENV HOME=/tmp
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/review"]
