param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $OrchestrateArgs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Find-GitBash {
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin\bash.exe"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }
  throw "Git Bash was not found. Install Git for Windows or run scripts/orchestrate.sh from a POSIX shell."
}

function ConvertTo-GitBashPath([string] $Path) {
  $full = [System.IO.Path]::GetFullPath($Path)
  $drive = $full.Substring(0, 1).ToLowerInvariant()
  $rest = $full.Substring(2).Replace('\', '/')
  return "/$drive$rest"
}

function Quote-BashArg([string] $Value) {
  return "'" + ($Value -replace "'", "'\''") + "'"
}

function Find-CodexBinary {
  $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  if (-not (Test-Path $root)) {
    return Find-CommandPath @('codex.exe', 'codex.cmd', 'codex')
  }
  $bundled = Get-ChildItem $root -Filter codex.exe -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if ($bundled) {
    return $bundled
  }
  return Find-CommandPath @('codex.exe', 'codex.cmd', 'codex')
}

function Find-CommandPath([string[]] $Names) {
  foreach ($name in $Names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) {
      return $cmd.Source
    }
  }
  return $null
}

function Set-AgentCommandIfMissing([string[]] $EnvNames, [string[]] $CommandNames) {
  foreach ($envName in $EnvNames) {
    if ([Environment]::GetEnvironmentVariable($envName, 'Process')) {
      return
    }
  }
  $path = Find-CommandPath $CommandNames
  if (-not $path) {
    return
  }
  [Environment]::SetEnvironmentVariable($EnvNames[0], $path, 'Process')
}

$bash = Find-GitBash

$windowsDirexioHome = if ($env:DIREXIO_HOME) { $env:DIREXIO_HOME } else { Join-Path $env:USERPROFILE '.direxio' }
$env:DIREXIO_WINDOWS_HOME = $windowsDirexioHome
$env:DIREXIO_HOME = ConvertTo-GitBashPath $windowsDirexioHome
$env:DIREXIO_LOCAL_PATH_STYLE = 'windows'

if (-not $env:DIREXIO_AGENT_WORKSPACE) {
  $env:DIREXIO_AGENT_WORKSPACE_WINDOWS = (Get-Location).ProviderPath
}

if ($env:P2P_WORKDIR) {
  $env:P2P_WORKDIR_WINDOWS = $env:P2P_WORKDIR
  $env:P2P_WORKDIR = ConvertTo-GitBashPath $env:P2P_WORKDIR
}

if (-not $env:DIREXIO_CODEX_COMMAND) {
  $codex = Find-CodexBinary
  if ($codex) { $env:DIREXIO_CODEX_COMMAND = $codex }
}

Set-AgentCommandIfMissing @('DIREXIO_CLAUDECODE_COMMAND', 'DIREXIO_CLAUDE_CODE_COMMAND', 'DIREXIO_CLAUDE_COMMAND') @('claude.exe', 'claude.cmd', 'claude', 'claude-code.exe', 'claude-code.cmd', 'claude-code')
Set-AgentCommandIfMissing @('DIREXIO_GEMINI_COMMAND') @('gemini.exe', 'gemini.cmd', 'gemini')
Set-AgentCommandIfMissing @('DIREXIO_COPILOT_COMMAND') @('copilot.exe', 'copilot.cmd', 'copilot')
Set-AgentCommandIfMissing @('DIREXIO_DEVIN_COMMAND') @('devin.exe', 'devin.cmd', 'devin')
Set-AgentCommandIfMissing @('DIREXIO_KIMI_COMMAND') @('kimi.exe', 'kimi.cmd', 'kimi')
Set-AgentCommandIfMissing @('DIREXIO_OPENCODE_COMMAND', 'DIREXIO_OPEN_CODE_COMMAND') @('opencode.exe', 'opencode.cmd', 'opencode')
Set-AgentCommandIfMissing @('DIREXIO_IFLOW_COMMAND') @('iflow.exe', 'iflow.cmd', 'iflow')
Set-AgentCommandIfMissing @('DIREXIO_QODER_COMMAND', 'DIREXIO_QODERCLI_COMMAND') @('qodercli.exe', 'qodercli.cmd', 'qodercli', 'qoder.exe', 'qoder.cmd', 'qoder')
Set-AgentCommandIfMissing @('DIREXIO_PI_COMMAND') @('pi.exe', 'pi.cmd', 'pi')
Set-AgentCommandIfMissing @('DIREXIO_ANTIGRAVITY_COMMAND', 'DIREXIO_AGY_COMMAND') @('agy.exe', 'agy.cmd', 'agy')
Set-AgentCommandIfMissing @('DIREXIO_OPENCLAW_COMMAND') @('openclaw.exe', 'openclaw.cmd', 'openclaw')
Set-AgentCommandIfMissing @('DIREXIO_HERMES_COMMAND') @('hermes.exe', 'hermes.cmd', 'hermes')

$repoRootForBash = ConvertTo-GitBashPath $RepoRoot
$quotedArgs = ($OrchestrateArgs | ForEach-Object { Quote-BashArg $_ }) -join ' '
$command = "cd $(Quote-BashArg $repoRootForBash) && ./scripts/orchestrate.sh $quotedArgs"

& $bash -lc $command
exit $LASTEXITCODE
