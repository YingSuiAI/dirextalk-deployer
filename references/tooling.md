# Tooling By OS

Prepare `bash`, `node`, `aws`, `ssh`, `scp`, `curl`, and at least one DNS lookup
tool. Always inspect first, then ask before installing or downloading.

## Detect

```bash
command -v bash node aws ssh scp curl
command -v dig nslookup getent
node --version
aws --version
```

On Windows PowerShell:

```powershell
Get-Command "C:\Program Files\Git\bin\bash.exe","C:\Program Files\Git\usr\bin\bash.exe",node,aws,ssh,scp,curl,nslookup,Resolve-DnsName -ErrorAction SilentlyContinue
```

## Windows

Preferred shell: Git Bash, MSYS2, Cygwin, or a working WSL distro. Do not use `C:\Windows\System32\bash.exe` unless `bash -lc 'echo ok'` succeeds.

Standard Git Bash usually does not include `dig`. Use Windows `Resolve-DnsName`
or `nslookup` for DNS checks instead of blocking deployment on `dig`.

Common system installs:

```powershell
winget install --id Git.Git --exact
winget install --id OpenJS.NodeJS.LTS --exact
winget install --id Amazon.AWSCLI --exact
```

Workspace-local fallback when package managers are unavailable:

```powershell
New-Item -ItemType Directory -Force -Path .tools\bin | Out-Null
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
brew install node awscli
```

If Homebrew is unavailable, ask before using the official AWS CLI pkg installer.
macOS already includes `ssh`, `scp`, `curl`, and `dig`.

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
