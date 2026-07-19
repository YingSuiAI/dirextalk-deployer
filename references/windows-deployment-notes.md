# Windows Deployment Notes

Tested on Windows 10+ with Git for Windows. Git Bash is the only supported
local lifecycle shell; these notes capture quirks that differ from Linux/macOS
deployments.

## Entry Point

From Git Bash at the repository root, verify Git before every lifecycle action:

```bash
case "$(uname -s)" in
  MINGW*) git_root=$(git --exec-path 2>/dev/null | sed 's#/mingw64/libexec/git-core$##'); command -v git >/dev/null && command -v cygpath >/dev/null && git --version | grep -q '\.windows\.' && [ -n "$git_root" ] && [ "$(cygpath -m "${EXEPATH:-}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s/bin' "$git_root" | tr '[:upper:]' '[:lower:]')" ] ;;
  Linux*|Darwin*) true ;;
  *) false ;;
esac
```

If the preflight fails, install Git for Windows from
<https://git-scm.com/download/win>, reopen Git Bash, and stop. The preflight
rejects PowerShell, MSYS2, and Cygwin on native Windows. Native WSL is supported
as a Linux host and uses its distribution's Bash, tools, and POSIX paths; do not
use it to operate a Git-Bash-owned service directory. Git Bash automatically stores
Windows-compatible consumer paths in `C:/...` form before invoking
Windows-native Node.js or local agent processes.

Path conversion at native-tool boundaries is explicit. The deployer converts
Node script/input paths, AWS CLI `file://` paths, curl output/header paths, and
local agent paths before invocation rather than relying on MSYS argv rewriting.
This matters when Hermes or another parent runtime exports
`MSYS_NO_PATHCONV=1`: Bash may redirect output into its real `/tmp` directory
while an unnormalized Windows process would otherwise look under `C:/tmp`.

Use the same Bash entrypoints as Linux/macOS. Destroy can use `DOMAIN` or an
explicit Windows-native state path:

```bash
bash scripts/orchestrate.sh status
DOMAIN=__DOMAIN__ bash scripts/orchestrate.sh
DOMAIN=__DOMAIN__ bash scripts/destroy.sh
bash scripts/destroy.sh "C:/Users/<you>/.dirextalk/nodes/<service_id>/state.json"
```

The npm test runner also uses Git Bash only. It keeps one controller shell and
runs selected test files sequentially; it never invokes `wsl.exe`. The isolated
suite starts one authenticated loopback Node JSON worker so repeated Bash JSON
calls reuse one native Node process and one connection per shell. `npm test`
selects current and neighboring contracts, while `npm run test:release` adds
package and skill-structure checks. `npm run test:quick` and `npm run test:stage`
are explicit broader lanes. Exhaustive EC2, legacy, updater, and runtime
matrices use explicit `npm run test:full` or manual Ubuntu CI dispatch. If Task
Manager shows many WSL processes during a test, inspect their parent process:
IntelliJ WSL toolchains and Docker Desktop commonly own those processes and
must be managed in those applications rather than killed by the deployer test
suite.

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

```bash
export DIREXTALK_CONNECT_AGENT=gemini
export DIREXTALK_GEMINI_COMMAND='C:/Tools/gemini.cmd'
```

For Cursor on Windows, S6 uses Cursor Agent CLI, not Cursor Desktop CLI. The
expected command is `%LOCALAPPDATA%\cursor-agent\agent.cmd`. S6 writes that path.
Generated agent options also default to `mode = "yolo"` so headless turns do not
stop at workspace trust prompts.
Before auto install, S6 also verifies the CLI exists and creates a
`versions/dist-package` junction to the latest version directory when legacy
launchers still expect that path. If Cursor Agent CLI is missing, install it
with Cursor's official Windows installer. Then reopen Git Bash and log in:

```bash
cursor_agent=$(cygpath -m "$LOCALAPPDATA/cursor-agent/agent.cmd")
"$cursor_agent" login
```

If Cursor Agent CLI is installed in a non-standard location, set:

```bash
export DIREXTALK_CONNECT_AGENT=cursor
export DIREXTALK_CURSOR_AGENT_COMMAND='C:/Path/To/agent.cmd'
```

Cursor Agent authentication may still require one interactive login:

```bash
cursor_agent=$(cygpath -m "$LOCALAPPDATA/cursor-agent/agent.cmd")
"$cursor_agent" status
"$cursor_agent" login
```

After login, rerun `bash scripts/orchestrate.sh`; S6 refreshes
`config.toml`, reinstalls the service-scoped daemon, and `verify runtime`
checks daemon logs for missing CLI, missing login, workspace trust, and other
agent backend failures.

Cursor MCP is host-managed and separate from the Cursor Agent CLI bridge. S6
does not generate or copy a token-bearing Cursor MCP JSON file. Any future host
enrollment must use a separately reviewed Cursor-native flow; App chat continues
through the Cursor Agent CLI bridge, with `[display]` defaulting to `compact` and
`tool_messages = false` so tool progress is not forwarded into the Matrix room.

For Codex Desktop, set `DIREXTALK_CODEX_COMMAND` to the real bundled
`codex.exe` with a `C:/...` path if the WindowsApps alias cannot be spawned by a
child process. Git Bash records `C:/Users/...` local paths for
`dirextalk-connect`; do not substitute `/mnt/c/...` or `/c/...` consumer paths.

## EC2 SSH Key Paths

SSH key files are written with Windows-compatible paths such as `C:/Users/.../.dirextalk/deploy/p2p-*.pem`. The deployer removes broad Windows ACL entries such as `Users`, `Authenticated Users`, `Everyone`, and Codex sandbox groups where possible, while keeping the current Windows user, `SYSTEM`, and `Administrators` on the file so OpenSSH does not reject the private key as too open. Forward-slash Windows paths are valid in Git Bash and Windows-native processes; no WSL conversion is required.

## Verifying Deployment

The Matrix endpoint returns HTTP 200 when the service is healthy:

```bash
curl -sk https://<domain>/_matrix/client/versions
```
