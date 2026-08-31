#!/bin/bash

# Put the public half of the signing key on the GitHub account. keys.sh trusts
# the key on this machine; this is the other half, and the only part of it that
# needs an account rather than a file.
#
# Everything that stops it is a skip, not a failure: no key yet, no gh, gh not
# logged in, or a token without the scope. On a fresh VM all of those are true
# when setup.sh reaches this, and the run should carry on regardless — you come
# back to it after 'gh auth login'.
#
# Safe to re-run: a key already on the account is left alone.

set -euo pipefail

signing_key="${1:-$HOME/.ssh/claude-sandbox.pub}"

if [ ! -f "$signing_key" ]; then
  echo "no signing key at $signing_key — run keys.sh first" >&2
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is not installed, so the signing key was not registered" >&2
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated, so the signing key was not registered. Run" >&2
  echo "'gh auth login', then this script." >&2
  exit 0
fi

# Signing keys are a different collection from authentication keys, under a
# scope of their own that 'gh auth login' does not ask for. Reading the list is
# what tells us whether the token has it, and doubles as the check that keeps a
# re-run from adding a key twice.
#
# write:ssh_signing_key is the least that works — the scopes nest, so it covers
# the read below as well. gh's own error suggests admin:, which is more than
# this needs.
registered=""
if ! registered="$(gh api user/ssh_signing_keys --jq '.[].key' 2>/dev/null)"; then
  echo "gh has no scope for signing keys, so the key was not registered. Grant" >&2
  echo "it and run this script again:" >&2
  echo "  gh auth refresh -h github.com -s write:ssh_signing_key" >&2
  exit 0
fi

# GitHub keeps the type and the body, and drops the comment, so compare on the
# two fields it stores.
key="$(awk '{print $1" "$2}' "$signing_key")"

if printf '%s\n' "$registered" | grep -qxF "$key"; then
  echo "the signing key is already on the GitHub account"
  exit 0
fi

gh ssh-key add "$signing_key" --type signing --title "$(hostname)"

echo "registered the signing key with GitHub as '$(hostname)'"
