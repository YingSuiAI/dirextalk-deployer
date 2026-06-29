# Tooling By OS

Prepare `bash`, `aws`, `jq`, `ssh`, `scp`, `curl`, and at least one DNS lookup
tool. Always inspect first, then ask before installing or downloading.

## Detect

```bash
command -v bash aws jq ssh scp curl
command -v dig nslookup getent
aws --version
jq --version
```

On Windows PowerShell:

```powershell
Get-Command "C:\Program Files\Git\bin\bash.exe","C:\Program Files\Git\usr\bin\bash.exe",aws,jq,ssh,scp,curl,nslookup,Resolve-DnsName -ErrorAction SilentlyContinue
```

## Windows

Preferred shell: Git Bash, MSYS2, Cygwin, or a working WSL distro. Do not use `C:\Windows\System32\bash.exe` unless `bash -lc 'echo ok'` succeeds.

Standard Git Bash usually does not include `dig`. Use Windows `Resolve-DnsName`
or `nslookup` for DNS checks instead of blocking deployment on `dig`.

Common system installs:

```powershell
winget install --id Git.Git --exact
winget install --id Amazon.AWSCLI --exact
winget install --id jqlang.jq --exact
```

Workspace-local fallback when package managers are unavailable:

```powershell
New-Item -ItemType Directory -Force -Path .tools\bin | Out-Null
Invoke-WebRequest -Uri https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe -OutFile .tools\bin\jq.exe
python -m venv .tools\awscli-venv
.\.tools\awscli-venv\Scripts\python.exe -m pip install --upgrade pip awscli
```

Create `.tools/bin/aws` for Git Bash:

```bash
#!/usr/bin/env bash
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/../awscli-venv/Scripts/python.exe" -m awscli "$@"
```

Run ops from Git Bash:

```powershell
& "C:\Program Files\Git\bin\bash.exe" -lc 'PATH="$PWD/.tools/bin:$PATH"; bash scripts/orchestrate.sh'
```

## macOS

Preferred installs:

```bash
brew install awscli jq
```

If Homebrew is unavailable, ask before using the official AWS CLI pkg installer.
macOS already includes `ssh`, `scp`, `curl`, and `dig`.

## Linux

Choose the detected package manager:

```bash
sudo apt-get update && sudo apt-get install -y awscli jq openssh-client curl dnsutils
sudo dnf install -y awscli jq openssh-clients curl bind-utils
sudo yum install -y awscli jq openssh-clients curl bind-utils
sudo pacman -Sy --needed aws-cli jq openssh curl bind-tools
sudo zypper install -y aws-cli jq openssh-clients curl bind-utils
```

If distro packages are too old or missing, ask before using the official AWS CLI zip installer.

## Credentials

Prefer a temporary non-root `DirexioDeployer` IAM user or role. If the user
provides an AWS access-key CSV, import it through the repository helper so root
identities are blocked and command output stays redacted:

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer <region>
export AWS_PROFILE=direxio-deployer
bash scripts/aws-credentials.sh verify direxio-deployer
```

Existing profiles can still be used when they are non-root:

```bash
aws configure --profile p2p-matrix
export AWS_PROFILE=p2p-matrix
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity
```

Never print secrets or commit them.
