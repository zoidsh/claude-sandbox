#!/bin/bash

# The entry point, and the only one. A VM arrives the way a provider hands it
# over — root over SSH, no unprivileged account yet — so the run has to start
# as root whether or not the account already exists.
#
#   curl -fsSL https://raw.githubusercontent.com/zoidsh/claude-sandbox/main/provision.sh | bash
#
# It creates that account, gives it the keys root is already reachable with,
# and hands everything else to setup.sh running as it. Nothing here duplicates
# setup.sh: this is the part that cannot be done from inside the account it is
# creating, which is why it is short and setup.sh is not.
#
# Safe to re-run: an existing user is reused, and keys are merged rather than
# replaced.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

user="${CLAUDE_SANDBOX_USER:-claude}"
repo_url="${CLAUDE_SANDBOX_REPO:-https://github.com/zoidsh/claude-sandbox.git}"

# Extra keys to authorize, one per line, for runs with nobody at the keyboard.
extra_keys="${SSH_PUBLIC_KEYS:-}"

root_keys=/root/.ssh/authorized_keys
sudoers_drop_in="/etc/sudoers.d/90-claude-sandbox-provision"

if [ "$(id -u)" -ne 0 ]; then
  echo "provision.sh has to run as root — it creates the user, authorizes keys" >&2
  echo "and lends itself sudo for the run. Log in as root and start again." >&2
  exit 1
fi

distro="$(. /etc/os-release && echo "$ID")"
if [ "$distro" != debian ]; then
  echo "unsupported distribution: $distro (expected debian)" >&2
  exit 1
fi

# A run killed outright — SIGKILL, a reboot, the VM pulled out from under it —
# never reaches the trap that takes the sudo grant at the end back out, and what
# it leaves behind is a standing passwordless sudo. Clearing it up front is what
# makes the re-run heal that rather than step over it.
rm -f "$sudoers_drop_in"

# Enough to create the user and clone the repo. bootstrap-system.sh, running
# later as the user, is what installs the rest.
apt-get update
apt-get install -y ca-certificates curl git openssh-client sudo

# User

if ! id -u "$user" >/dev/null 2>&1; then
  # bootstrap-system.sh switches this to zsh once zsh exists.
  useradd -m -s /bin/bash "$user"
  echo "created $user"
fi

usermod -aG sudo "$user"

home="$(getent passwd "$user" | cut -d: -f6)"

# useradd leaves the account locked, so sudo has nothing to authenticate
# against later. Group membership alone is useless without this.
#
# Generated rather than asked for, and printed at the end of the run: that is
# the only copy, so a headless provision ends with a usable sudo too.
#
# Empty unless this run set one, which is what the closing block keys off.
generated_password=""

set_password() {
  # head takes a fixed count and exits on its own, so nothing in the pipeline
  # dies of SIGPIPE and trips pipefail.
  local candidate
  candidate="$(head -c 18 /dev/urandom | base64)"

  if printf '%s:%s\n' "$user" "$candidate" | chpasswd; then
    generated_password="$candidate"
  else
    echo "warning: no password set. Run 'passwd $user' before relying on sudo." >&2
  fi
}

if [ "$(passwd -S "$user" | awk '{print $2}')" != P ]; then
  set_password
elif [ -t 0 ]; then
  echo
  read -r -p "$user already has a password. Replace it with a generated one? [y/N] " answer
  if [ "$answer" = y ] || [ "$answer" = Y ]; then
    set_password
  fi
fi

# SSH keys

# The directory has to be user-owned either way, or the VM cannot write
# known_hosts, which breaks git over SSH from inside it.
install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"

authorized_keys="$home/.ssh/authorized_keys"
staged="$(mktemp)"
trap 'rm -f "$staged" "$staged.one"' EXIT

# Whatever is already there stays: cloud-init's key, or a previous run's.
[ -f "$authorized_keys" ] && cat "$authorized_keys" >>"$staged"
[ -s "$root_keys" ] && cat "$root_keys" >>"$staged"
[ -n "$extra_keys" ] && printf '%s\n' "$extra_keys" >>"$staged"

collect_keys() {
  grep -Ev '^[[:space:]]*(#|$)' "$staged" | sort -u >"$staged.one" || true
  mv "$staged.one" "$staged"
}

collect_keys

# Nothing to inherit and someone is watching, so ask rather than quietly leave
# the account unreachable.
if [ ! -s "$staged" ] && [ -t 0 ]; then
  echo
  echo "No SSH public key found for $user, and root has none to inherit."
  echo "Paste one, e.g. 'ssh-ed25519 AAAA... tim@macbook'."
  echo "Enter on an empty line moves on."

  while :; do
    read -r -p "key> " pasted || break
    [ -n "$pasted" ] || break

    printf '%s\n' "$pasted" >"$staged.one"

    if ssh-keygen -l -f "$staged.one" >/dev/null 2>&1; then
      cat "$staged.one" >>"$staged"
      echo "  ok — paste another, or Enter to move on."
    else
      echo "  that does not parse as a public key; try again." >&2
    fi

    rm -f "$staged.one"
  done

  collect_keys
fi

if [ -s "$staged" ]; then
  # install(1) sets owner and mode as it creates, so the file is never
  # world-readable in between.
  install -m 0600 -o "$user" -g "$user" "$staged" "$authorized_keys"
  echo "authorized $(wc -l <"$authorized_keys") key(s) for $user"
else
  # setup.sh reaches keys.sh later, and harden-ssh.sh holds off until then.
  echo "no keys authorized yet for $user — keys.sh will ask"
fi

# The repo

target="${CLAUDE_SANDBOX_DIR:-$home/claude-sandbox}"

if [ -d "$target/.git" ]; then
  sudo -u "$user" git -C "$target" pull --ff-only
else
  sudo -u "$user" git clone "$repo_url" "$target"
fi

# Hand over

# setup.sh sudos its way through a long apt run as $user, and the password just
# set would expire out of sudo's timestamp partway through. Lift the
# requirement for the length of this run only — the trap goes on first, so a
# rejected sudoers file cannot leave a standing grant behind.
trap 'rm -f "$staged" "$staged.one" "$sudoers_drop_in"' EXIT

cat >"$sudoers_drop_in" <<EOF
$user ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "$sudoers_drop_in"
visudo -cf "$sudoers_drop_in" >/dev/null

# bootstrap-system.sh makes zsh the login shell, so a second run would hand
# setup.sh to a shell whose rc files expect a terminal. -s keeps it bash.
#
# stdin may also be the curl pipe feeding this script, so pass the real
# terminal along — setup.sh's key prompts have nowhere to go otherwise.
if (exec </dev/tty) 2>/dev/null; then
  su - "$user" -s /bin/bash -c "$target/setup.sh" </dev/tty
else
  su - "$user" -s /bin/bash -c "$target/setup.sh"
fi

cat <<EOF

Provisioned. Before closing this session, from a second terminal:

    ssh $user@<host>
    sudo -v && docker ps && claude --version

One more thing worth knowing: docker writes its own iptables rules and goes
around a host firewall, so a firewall at the provider is the one that counts.
EOF

# Last, so the one thing this run produced and cannot show again is still on
# screen. The signing key was pasted in, not made here, so keys.sh printing it
# once is enough.

if [ -n "$generated_password" ]; then
  cat <<EOF

Password for $user, generated and shown once — sudo wants it, and nothing
else has a copy:

    $generated_password
EOF
fi
