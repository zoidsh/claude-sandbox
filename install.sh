#!/bin/bash

# Fetch the private half and let it take over. Everything personal — the shell,
# the prompt, the runtimes, the Claude Code configuration — lives in
# claude-dotfiles, so all this script does is get it onto the machine and run
# its installer.
#
# That needs an authenticated gh, which a fresh VM does not have when setup.sh
# first reaches this. So it says what is missing and returns, and login.sh runs
# it again once there is a token. This is also the script to rerun by hand
# after one expires.
#
# Safe to re-run: an existing clone is pulled rather than recloned.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated — run $repo/login.sh, which logs in and comes" >&2
  echo "back here for the dotfiles" >&2
  exit 0
fi

dotfiles="${CLAUDE_DOTFILES_DIR:-$HOME/claude-dotfiles}"

# Nobody but the owner can clone it, so a failure here is a message rather than
# the end of the run: the machine claude-sandbox built still works.
if [ -d "$dotfiles/.git" ]; then
  git -C "$dotfiles" pull --ff-only ||
    echo "could not update $dotfiles — leaving it as it is" >&2
else
  gh repo clone "${CLAUDE_DOTFILES_REPO:-zoidsh/claude-dotfiles}" "$dotfiles" ||
    echo "could not clone the dotfiles repo — the shell stays on bash" >&2
fi

if [ -x "$dotfiles/install.sh" ]; then
  "$dotfiles/install.sh"
fi

# The signing key is claude-sandbox's business — keys.sh pastes it — but
# registering it needs the gh that only exists by this point.
"$repo/register-signing-key.sh"
