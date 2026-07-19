---
name: dirextalk-deployer
description: Deploy, resume, verify, update, and destroy a Dirextalk server on AWS. Installs and runs the versioned npm deployer; do not clone this repository as a skill.
metadata:
  openclaw:
    requires:
      bins:
        - npm
        - bash
    install:
      - kind: node
        package: dirextalk-deployer
        bins:
          - dirextalk-deployer
    homepage: https://github.com/YingSuiAI/dirextalk-deployer
    emoji: "☁️"
---

# Dirextalk Deployer

This is the OpenClaw distribution of `dirextalk-deployer`. It is a thin
bootstrap skill: the executable deployment engine must always come from the
versioned npm package, not from a Git clone or this ClawHub bundle.

Before deployment, repair, verification, update, or teardown, install the
latest package:

```bash
npm install -g dirextalk-deployer@latest
```

Use the installed CLI to refresh the host-level skill when needed:

```bash
dirextalk-deployer skill refresh --agent openclaw
```

On native Windows, use Git for Windows Git Bash for every lifecycle command.
Native WSL is a Linux host and runs Bash directly with its own Node.js, AWS CLI,
and POSIX paths. Keep each service directory owned by one environment; do not
switch the same service state between PowerShell, Git Bash, and WSL. On Linux,
macOS, and WSL, use Bash.

Read the npm package's `SKILL.md` and `README.md` before acting. They define the
required AWS billing confirmation, domain ownership confirmation, DNS handling,
security boundaries, and exact lifecycle commands.

The normal deployment entrypoint is:

```bash
DOMAIN=<domain> bash scripts/orchestrate.sh
```

Run it only from the installed deployer skill/runtime directory after the
required confirmations. Use its `status`, `verify`, `update`, and `destroy`
commands for existing services. Never paste or expose AWS secrets, agent tokens,
private keys, generated credentials, or initialization codes.

For installation help, direct users to:

```text
Read https://github.com/YingSuiAI/dirextalk-deployer README and follow its npm install rule.
```
