# Windows Deployment Notes

Tested on Windows 10+ with Git Bash / MSYS2. These notes capture quirks that differ from Linux/macOS deployments.

## Entry Point

Use the PowerShell wrapper from the repository root:

```powershell
.\scripts\orchestrate.ps1 status
.\scripts\orchestrate.ps1
.\scripts\destroy.ps1
```

The wrappers find a working Git for Windows or MSYS2 Bash on `PATH` and use it for the Bash state machine, but set `DIREXTALK_LOCAL_PATH_STYLE=windows` so S6 stores Windows-compatible consumer paths and renders recommendation commands as valid PowerShell. Set `DIREXTALK_BASH_COMMAND` for a custom executable location. The wrappers reject implicit Windows WSL aliases; use WSL Bash directly only when you intentionally want WSL-owned local paths. POSIX hosts receive Bash recommendations.

Destroy can use `DOMAIN` or an explicit Windows state path:

```powershell
$env:DOMAIN = "__DOMAIN__"
.\scripts\destroy.ps1

.\scripts\destroy.ps1 "$env:USERPROFILE\.dirextalk\nodes\<service_id>\state.json"
```

## Background Process Output Buffering

When running `orchestrate.sh` as a background process, bash may buffer stdout because it is not connected to a terminal. The process still writes state to `~/.dirextalk/nodes/<service_id>/state.json`.

Poll progress with:

```bash
node scripts/json.mjs get ~/.dirextalk/nodes/<service_id>/state.json phase
node scripts/json.mjs get ~/.dirextalk/nodes/<service_id>/state.json phases
```

For real-time tailing, use `stdbuf` when available:

```bash
stdbuf -oL bash scripts/orchestrate.sh 2>&1
```

## DNS Diagnostics

- `dig` is not always available in Git Bash. Use `nslookup` or Route53 API output.
- Chinese locale can garble `nslookup` text; DNS resolution still works.
- When local DNS cache is stale but the record is correct, pin the IP:

```bash
curl -sk --resolve __DOMAIN__:443:__EIP__ https://__DOMAIN__/healthz
```

## AWS Proxy Bypass

`lib/aws.sh` sets `NO_PROXY=*` and unsets proxy variables for AWS CLI calls. If AWS still fails with proxy errors, check:

```bash
echo "HTTP_PROXY=$HTTP_PROXY"
echo "HTTPS_PROXY=$HTTPS_PROXY"
cat ~/.aws/config
```

## Reading AWS Credential CSVs

Windows terminal output may redact AWS keys. If a CSV appears truncated in output, read it without printing secrets and configure AWS CLI directly. Never print or log credential values.

## Runtime Detection

S6 checks active runtime signals before historical config directories. If detection is ambiguous on Windows, set:

```bash
DIREXTALK_CONNECT_AGENT=claudecode
```

or another supported dirextalk-connect agent before running `scripts/orchestrate.sh`. Supported bridge agents are `acp`, `antigravity`, `claudecode`, `codex`, `copilot`, `cursor`, `devin`, `gemini`, `iflow`, `kimi`, `opencode`, `pi`, `qoder`, `reasonix`, and `tmux`.

## dirextalk-connect

The npm path is service-scoped by default, so each domain has its own package copy and short wrapper:

```bash
npm install --prefix "$HOME/.dirextalk/nodes/<service_id>/dirextalk-connect" dirextalk-connect@latest
"$HOME/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect.cmd" daemon install --config "$HOME/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml" --service-name <service_id> --force
"$HOME/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect.cmd" daemon status --service-name <service_id>
"$HOME/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect.cmd" daemon logs --service-name <service_id> -n 120
```

In `DIREXTALK_AGENT_INSTALL=auto`, S6 waits for the daemon to report `Running`
and for logs to show `dirextalk-connect is running`. Cursor Agent CLI missing,
not logged in, workspace trust, ACP startup, or agent offline errors in the logs
make S6 fail instead of reporting deployment success.

If the command is not found after install, check the service-scoped bin directory:

```bash
ls "$HOME/.dirextalk/nodes/<service_id>/dirextalk-connect"
```

If an agent executable cannot be spawned from PATH, set a generic or agent-specific command before running S6:

```powershell
$env:DIREXTALK_CONNECT_AGENT = "gemini"
$env:DIREXTALK_GEMINI_COMMAND = "C:\Tools\gemini.cmd"
```

For Cursor on Windows, S6 uses Cursor Agent CLI, not Cursor Desktop CLI. The
expected command is `%LOCALAPPDATA%\cursor-agent\agent.cmd`. S6 writes that path.
Generated agent options also default to `mode = "yolo"` so headless turns do not
stop at workspace trust prompts.
Before auto install, S6 also verifies the CLI exists and creates a
`versions/dist-package` junction to the latest version directory when legacy
launchers still expect that path. If Cursor Agent CLI is missing, install it:

```powershell
irm 'https://cursor.com/install?win32=true' | iex
& "$env:LOCALAPPDATA\cursor-agent\agent.cmd" login
```

If Cursor Agent CLI is installed in a non-standard location, set:

```powershell
$env:DIREXTALK_CONNECT_AGENT = "cursor"
$env:DIREXTALK_CURSOR_AGENT_COMMAND = "C:\Path\To\agent.cmd"
```

Cursor Agent authentication may still require one interactive login:

```powershell
& "$env:LOCALAPPDATA\cursor-agent\agent.cmd" status
& "$env:LOCALAPPDATA\cursor-agent\agent.cmd" login
```

After login, rerun `.\scripts\orchestrate.ps1`; S6 refreshes
`config.toml`, reinstalls the service-scoped daemon, and `verify runtime`
checks daemon logs for missing CLI, missing login, workspace trust, and other
agent backend failures.

Cursor MCP is host-managed and separate from the Cursor Agent CLI bridge. S6
does not generate or copy a token-bearing Cursor MCP JSON file. Any future host
enrollment must use a separately reviewed Cursor-native flow; App chat continues
through the Cursor Agent CLI bridge, with `[display]` defaulting to `compact` and
`tool_messages = false` so tool progress is not forwarded into the Matrix room.

For Codex Desktop, the wrapper also tries to find the real bundled `codex.exe` because WindowsApps aliases cannot always be spawned by child processes:

```powershell
$codex = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') -Filter codex.exe -Recurse |
  Select-Object -First 1 -ExpandProperty FullName
$env:DIREXTALK_CODEX_COMMAND = $codex
```

Use the Windows user profile path recorded by the PowerShell wrapper for files consumed by `dirextalk-connect`. State and displayed local paths use `C:/Users/...` form, which PowerShell and Windows-native processes accept; do not substitute `/mnt/c/...` or `/c/...` consumer paths.

## EC2 SSH Key Paths

SSH key files are written with Windows-compatible paths such as `C:/Users/.../.dirextalk/deploy/p2p-*.pem`. The deployer removes broad Windows ACL entries such as `Users`, `Authenticated Users`, `Everyone`, and Codex sandbox groups where possible, while keeping the current Windows user, `SYSTEM`, and `Administrators` on the file so OpenSSH does not reject the private key as too open. Forward-slash Windows paths are valid in PowerShell; no WSL conversion is required.

## Verifying Deployment

The Matrix endpoint returns HTTP 200 when the service is healthy:

```bash
curl -sk https://<domain>/_matrix/client/versions
```
