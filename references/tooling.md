# Tooling By OS

Prepare Git, `bash`, `node`, `aws`, `ssh`, `curl`, and at least one DNS lookup
tool. Always inspect first, then ask before installing or downloading.

## Detect

```bash
git --version
bash --version
command -v node aws ssh curl
command -v dig nslookup getent
node --version
aws --version
```

## Windows

Git Bash from Git for Windows is the only supported lifecycle shell. Before a
Windows lifecycle action, run the Git Bash preflight from
`references/agent-targets.md`. It must find `cygpath`, a `.windows.` Git
version, a `MINGW*` shell, and one shared Git for Windows installation root;
otherwise tell the user to install Git for Windows from
<https://git-scm.com/download/win>, reopen Git Bash, and stop. Do not substitute
PowerShell, MSYS2, Cygwin, or WSL.

Standard Git Bash usually does not include `dig`. Use `nslookup` for DNS checks
instead of blocking deployment on `dig`.

Install Git for Windows, Node.js LTS, and AWS CLI with their official Windows
installers. Reopen Git Bash after installation and rerun the detection block.
For a workspace-local AWS CLI fallback when package managers are unavailable:

```bash
mkdir -p .tools/bin
python -m venv .tools/awscli-venv
.tools/awscli-venv/Scripts/python.exe -m pip install --upgrade pip awscli
```

Create `.tools/bin/aws` for Git Bash:

```bash
#!/usr/bin/env bash
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/../awscli-venv/Scripts/python.exe" -m awscli "$@"
```

Run all lifecycle operations from Git Bash:

```bash
PATH="$PWD/.tools/bin:$PATH" bash scripts/orchestrate.sh
```

## macOS

Preferred installs:

```bash
brew install node awscli
```

If Homebrew is unavailable, ask before using the official AWS CLI pkg installer.
macOS already includes `ssh`, `curl`, and `dig`.

## Linux

Choose the detected package manager:

```bash
sudo apt-get update && sudo apt-get install -y nodejs awscli openssh-client curl dnsutils
sudo dnf install -y nodejs awscli openssh-clients curl bind-utils
sudo yum install -y nodejs awscli openssh-clients curl bind-utils
sudo pacman -Sy --needed nodejs aws-cli openssh curl bind-tools
sudo zypper install -y nodejs aws-cli openssh-clients curl bind-utils
```

If distro packages are too old or missing, ask before using the official AWS CLI zip installer.

## Credentials

For first-time setup, offer a root access key as the fastest path and a
temporary `DirextalkDeployer` IAM user or role as the safer path. Root keys are
highly privileged; the operator must save the CSV securely, never paste or
commit it, and rotate or delete it after deployment. If the user provides an
AWS access-key CSV, import it through the repository helper so command output
stays redacted and the identity is marked as `root=true|false`:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer <region>
export AWS_PROFILE=dirextalk-deployer
bash scripts/aws-credentials.sh verify dirextalk-deployer
```

Existing profiles can still be used, including root profiles when the operator
explicitly chooses root credentials:

```bash
aws configure --profile dirextalk-deployer
export AWS_PROFILE=dirextalk-deployer
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity
```

Never print secrets or commit them.
