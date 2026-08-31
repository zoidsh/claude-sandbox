#!/bin/bash

# Run setup.sh end to end in a throwaway container per image, then assert the
# result. Defaults to the release the repo claims to support.
#
#   test/run.sh                  # debian:13
#   test/run.sh debian:12        # another release
#   KEEP=1 test/run.sh           # leave the containers around to poke at
#
# Nothing here touches the machine it runs on; every change lands in the
# container.

set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user=tester

images=("$@")
if [ ${#images[@]} -eq 0 ]; then
  images=(debian:13)
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker is not available" >&2
  exit 1
fi

run_in_container() {
  docker exec -u "$user" -e USER="$user" -e HOME="/home/$user" \
    -e DEBIAN_FRONTEND=noninteractive "$1" bash "/home/$user/claude-sandbox/$2"
}

start_container() {
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" -v "$repo:/repo:ro" "$2" sleep 7200 >/dev/null
}

# provision.sh clones rather than copying, so its half of the suite sees the
# last commit and not the working tree.
if [ -n "$(git -C "$repo" status --porcelain)" ]; then
  echo "note: uncommitted changes — the provision.sh stage tests HEAD without them"
fi

# A key for provision.sh to authorize. The private half goes out with the
# temporary directory; nothing is meant to log in with it.
keydir="$(mktemp -d)"
trap 'rm -rf "$keydir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C provision-test -f "$keydir/key"
public_key="$(cat "$keydir/key.pub")"

failed=0

for image in "${images[@]}"; do
  container="claude-sandbox-test-$(echo "$image" | tr ':/.' '---')"
  log="$(mktemp)"

  echo "==> $image"

  start_container "$container" "$image"

  # A fresh VM has a sudo-capable non-root user; the base images do not.
  docker exec -e DEBIAN_FRONTEND=noninteractive "$container" bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq sudo passwd adduser >/dev/null
    useradd -m -s /bin/bash -G sudo $user
    echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user
    cp -r /repo /home/$user/claude-sandbox
    chown -R $user:$user /home/$user/claude-sandbox
  " >>"$log" 2>&1

  stage_failed=0

  # provision.sh is the entry point, so setup.sh has to turn root away: every
  # path in it lands in one user's $HOME, and root running it would scatter
  # them through /root.
  echo "--- setup.sh as root"
  if docker exec -e DEBIAN_FRONTEND=noninteractive "$container" \
    bash "/home/$user/claude-sandbox/setup.sh" >>"$log" 2>&1; then
    echo "  FAIL  setup.sh refuses to run as root"
    stage_failed=1
  else
    echo "  ok    setup.sh refuses to run as root"
  fi

  echo "--- setup.sh"
  if ! run_in_container "$container" setup.sh >>"$log" 2>&1; then
    echo "  FAIL  setup.sh exited non-zero"
    stage_failed=1
  fi

  if [ "$stage_failed" -eq 0 ]; then
    run_in_container "$container" test/assert.sh || stage_failed=1

    # install.sh is documented as safe to re-run, so prove it.
    echo "--- install.sh again"
    if run_in_container "$container" install.sh >>"$log" 2>&1; then
      run_in_container "$container" test/assert.sh || stage_failed=1
    else
      echo "  FAIL  install.sh is not idempotent"
      stage_failed=1
    fi

    # setup.sh skipped keys.sh for want of a terminal, so drive it under a pty
    # from bsdutils' script(1) — Essential, so it is on every Debian. A throwaway
    # key stands in for the paste, and the empty line after it ends the
    # authorized_keys list. Signing a commit and verifying it is the assertion:
    # it exercises the derived .pub and the trust list keys.sh writes, and fails
    # if the paste handling is wrong.
    #
    # The signing config is written here rather than coming from a linked
    # .gitconfig, because that file lives in claude-dotfiles now and no
    # container ever gets that far. It has to be in place before keys.sh runs:
    # user.email is what keys.sh writes into allowed_signers as the principal,
    # and a signature verifies against nothing if the two disagree.
    echo "--- keys.sh"
    if docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      git config --global user.name tester
      git config --global user.email tester@example.com
      git config --global gpg.format ssh
      git config --global user.signingkey '~/.ssh/claude-sandbox.pub'
      git config --global gpg.ssh.allowedSignersFile '~/.ssh/allowed_signers'
      git config --global commit.gpgsign true
      ssh-keygen -q -t ed25519 -N '' -C pasted -f /tmp/pasted
      { cat /tmp/pasted; printf '\n'; } |
        script -qec /home/$user/claude-sandbox/keys.sh /dev/null
      test ! -L /home/$user/.ssh/allowed_signers
      cmp -s /tmp/pasted /home/$user/.ssh/claude-sandbox
      rm -rf /tmp/signing && mkdir /tmp/signing && cd /tmp/signing
      git init -q .
      git commit --allow-empty -q -m signed
      git log --format='%G?' -1 | grep -qx G
    " >>"$log" 2>&1; then
      echo "  ok    keys.sh installs a pasted signing key that verifies"
    else
      echo "  FAIL  keys.sh installs a pasted signing key that verifies"
      stage_failed=1
    fi

    # Non-empty is not the same as usable: a wrapped or truncated paste leaves
    # a file with lines in it that parse as nothing, and hardening on the
    # strength of that is a box nobody can log in to.
    echo "--- harden-ssh.sh with an unusable key"
    docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      mkdir -p /home/$user/.ssh
      chmod 700 /home/$user/.ssh
      printf 'ssh-ed25519 AAAAtruncated\n' > /home/$user/.ssh/authorized_keys
    " >>"$log" 2>&1

    if run_in_container "$container" harden-ssh.sh >>"$log" 2>&1 &&
      docker exec "$container" test ! -f /etc/ssh/sshd_config.d/10-hardening.conf; then
      echo "  ok    harden-ssh.sh refuses a key sshd cannot use"
    else
      echo "  FAIL  harden-ssh.sh refuses a key sshd cannot use"
      stage_failed=1
    fi

    # setup.sh leaves the box unhardened, since keys.sh cannot prompt without a
    # terminal. Seed a key the way a real run would and the drop-in should land.
    echo "--- harden-ssh.sh"
    docker exec -u "$user" -e HOME="/home/$user" "$container" bash -c "
      set -e
      mkdir -p /home/$user/.ssh
      chmod 700 /home/$user/.ssh
      ssh-keygen -q -t ed25519 -N '' -C $user -f /tmp/$user
      install -m 0600 /tmp/$user.pub /home/$user/.ssh/authorized_keys
    " >>"$log" 2>&1

    if run_in_container "$container" harden-ssh.sh >>"$log" 2>&1; then
      run_in_container "$container" test/assert.sh || stage_failed=1
    else
      echo "  FAIL  harden-ssh.sh exited non-zero"
      stage_failed=1
    fi
  fi

  # The other entry point, from the other end: a bare image with nothing but
  # root, where the user setup.sh needs does not exist yet. A key is handed in
  # the way a headless run would, so hardening happens on the way through.
  echo "--- provision.sh"
  provision_container="$container-provision"
  start_container "$provision_container" "$image"

  # git refuses to clone from a directory owned by someone else, and the
  # mounted repo belongs to whoever checked it out — uid 1000 on a dev box,
  # someone else on a CI runner. The container is thrown away either way.
  docker exec -e DEBIAN_FRONTEND=noninteractive "$provision_container" bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq git >/dev/null
    git config --system --add safe.directory '*'
  " >>"$log" 2>&1

  if docker exec \
    -e DEBIAN_FRONTEND=noninteractive \
    -e CLAUDE_SANDBOX_USER="$user" \
    -e CLAUDE_SANDBOX_REPO=/repo \
    -e SSH_PUBLIC_KEYS="$public_key" \
    "$provision_container" bash /repo/provision.sh >>"$log" 2>&1; then
    run_in_container "$provision_container" test/assert.sh || stage_failed=1

    # Two things only root can see: that sshd will parse what was installed,
    # and that the sudo grant provision.sh lends itself for the run is gone
    # again. Left behind, that grant would be a standing one.
    if docker exec "$provision_container" /usr/sbin/sshd -t >>"$log" 2>&1; then
      echo "  ok    sshd accepts the drop-in"
    else
      echo "  FAIL  sshd accepts the drop-in"
      stage_failed=1
    fi

    if docker exec "$provision_container" \
      test ! -f /etc/sudoers.d/90-claude-sandbox-provision; then
      echo "  ok    the temporary sudo grant was withdrawn"
    else
      echo "  FAIL  the temporary sudo grant was withdrawn"
      stage_failed=1
    fi

    # The password is generated, so a run with nobody watching leaves a usable
    # sudo behind rather than the locked account useradd creates.
    if docker exec "$provision_container" \
      bash -c "passwd -S $user | awk '{print \$2}' | grep -qx P"; then
      echo "  ok    the user has a password"
    else
      echo "  FAIL  the user has a password"
      stage_failed=1
    fi
  else
    echo "  FAIL  provision.sh exited non-zero"
    stage_failed=1
  fi

  if [ "$stage_failed" -ne 0 ]; then
    failed=1
    echo "--- last 40 lines of output"
    tail -40 "$log" | sed 's/^/  /'
    echo "  full log: $log"
  else
    rm -f "$log"
  fi

  if [ "${KEEP:-}" = 1 ]; then
    echo "  containers kept: $container $provision_container"
  else
    docker rm -f "$container" "$provision_container" >/dev/null 2>&1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi

echo "PASSED"
