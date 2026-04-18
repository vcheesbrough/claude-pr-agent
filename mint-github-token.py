#!/usr/bin/env python3
"""
Mint a short-lived GitHub App installation access token.

Reads from env:
  PR_REVIEWER_GH_APP_ID                 — numeric App ID
  PR_REVIEWER_GH_APP_INSTALLATION_ID    — numeric Installation ID
  PR_REVIEWER_GH_APP_PRIVATE_KEY_B64    — base64-encoded PEM private key

Prints the installation token to stdout on success. Exits non-zero on failure.
"""

import base64
import os
import sys
import time

import jwt
import requests


def fail(msg: str) -> None:
    print(f"mint-github-token: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    app_id = os.environ.get("PR_REVIEWER_GH_APP_ID")
    install_id = os.environ.get("PR_REVIEWER_GH_APP_INSTALLATION_ID")
    key_b64 = os.environ.get("PR_REVIEWER_GH_APP_PRIVATE_KEY_B64")

    if not app_id or not install_id or not key_b64:
        fail("missing one of PR_REVIEWER_GH_APP_ID, "
             "PR_REVIEWER_GH_APP_INSTALLATION_ID, "
             "PR_REVIEWER_GH_APP_PRIVATE_KEY_B64")

    try:
        private_key = base64.b64decode(key_b64).decode("utf-8")
    except Exception as e:
        fail(f"could not base64-decode private key: {e}")

    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 9 * 60, "iss": app_id}

    try:
        app_jwt = jwt.encode(payload, private_key, algorithm="RS256")
    except Exception as e:
        fail(f"could not sign JWT: {e}")

    url = f"https://api.github.com/app/installations/{install_id}/access_tokens"
    headers = {
        "Authorization": f"Bearer {app_jwt}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    try:
        resp = requests.post(url, headers=headers, timeout=15)
    except requests.RequestException as e:
        fail(f"token exchange request failed: {e}")

    if resp.status_code != 201:
        fail(f"token exchange returned {resp.status_code}: {resp.text}")

    token = resp.json().get("token")
    if not token:
        fail(f"response missing 'token' field: {resp.text}")

    print(token)


if __name__ == "__main__":
    main()
