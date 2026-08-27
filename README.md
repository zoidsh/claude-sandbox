# Claude Sandbox

[![test](https://github.com/zoidsh/claude-sandbox/actions/workflows/test.yml/badge.svg)](https://github.com/zoidsh/claude-sandbox/actions/workflows/test.yml)

Provisioning for a Debian VM dedicated to running Claude Code, which is why the
machine runs it with `bypassPermissions` — there is nothing on it worth
guarding Claude from.

As root, which is how a VM arrives from a provider:

```sh
curl -fsSL https://raw.githubusercontent.com/zoidsh/claude-sandbox/main/provision.sh | bash
```

That is the only entry point. It creates the account, clones this repo and runs
`setup.sh` as that user, which builds the machine and then fetches the private
`claude-dotfiles` — the shell, the prompt, the runtimes and `~/.claude`.

`login.sh` drives all three account logins on the way through — GitHub,
tailscale and Claude Code — so what is left afterwards is to log out and back
in, for the docker group and the login shell, and to write the tailscale ssh
policy. The machine advertises ssh on the tailnet; who may use it is a rule in
the admin console, and tailscaled answers those sessions itself, so the sshd
hardening has no say over them.

`CLAUDE.md` has the details: the order the scripts run in, the constraints that
are not obvious from reading them, and how to test.
