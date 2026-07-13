param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $OrchestrateArgs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'lib\windows-paths.ps1')
. (Join-Path $ScriptDir 'lib\windows-network-env.ps1')
. (Join-Path $ScriptDir 'lib\windows-bash.ps1')

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

function Test-AnyEnvSet([string[]] $EnvNames) {
  foreach ($envName in $EnvNames) {
    if ([Environment]::GetEnvironmentVariable($envName, 'Process')) {
      return $true
    }
  }
  return $false
}

function Set-AgentCommandIfMissing([string[]] $EnvNames, [string[]] $CommandNames) {
  if (Test-AnyEnvSet $EnvNames) {
    return
  }
  $path = Find-CommandPath $CommandNames
  if (-not $path) {
    return
  }
  [Environment]::SetEnvironmentVariable($EnvNames[0], $path, 'Process')
}

function Find-OpenCodeBinary {
  $path = Find-CommandPath @('opencode.exe', 'opencode.cmd', 'opencode')
  if ($path) {
    return $path
  }

  $npm = Find-CommandPath @('npm.cmd', 'npm.exe', 'npm')
  if (-not $npm) {
    return $null
  }

  try {
    $prefix = (& $npm prefix -g 2>$null | Select-Object -First 1)
  } catch {
    $prefix = $null
  }
  if (-not $prefix) {
    return $null
  }

  $prefix = $prefix.Trim()
  $candidates = @(
    (Join-Path $prefix 'node_modules\opencode-ai\bin\opencode.exe'),
    (Join-Path $prefix 'node_modules\opencode-ai\bin\opencode.cmd'),
    (Join-Path $prefix 'node_modules\.bin\opencode.cmd'),
    (Join-Path $prefix 'node_modules\.bin\opencode.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }
  return $null
}

function Set-OpenCodeCommandIfMissing {
  $envNames = @('DIREXTALK_OPENCODE_COMMAND', 'DIREXTALK_OPEN_CODE_COMMAND', 'DIREXTALK_OPENCODE_AI_COMMAND')
  if (Test-AnyEnvSet $envNames) {
    return
  }
  $path = Find-OpenCodeBinary
  if ($path) {
    $env:DIREXTALK_OPENCODE_COMMAND = $path
  }
}

$bash = Resolve-DirextalkBashCommand

$windowsDirextalkHome = Resolve-WindowsDirextalkHome
$env:DIREXTALK_WINDOWS_HOME = $windowsDirextalkHome
$env:DIREXTALK_HOME = $windowsDirextalkHome.Replace('\', '/')
$env:DIREXTALK_LOCAL_PATH_STYLE = 'windows'

if (-not $env:DIREXTALK_AGENT_WORKSPACE) {
  $env:DIREXTALK_AGENT_WORKSPACE_WINDOWS = (Get-Location).ProviderPath
}

if ($env:DIREXTALK_WORKDIR) {
  $env:DIREXTALK_WORKDIR_WINDOWS = $env:DIREXTALK_WORKDIR
  $env:DIREXTALK_WORKDIR = ([IO.Path]::GetFullPath($env:DIREXTALK_WORKDIR)).Replace('\', '/')
}

if (-not $env:DIREXTALK_CODEX_COMMAND) {
  $codex = Find-CodexBinary
  if ($codex) { $env:DIREXTALK_CODEX_COMMAND = $codex }
}

Set-AgentCommandIfMissing @('DIREXTALK_CLAUDECODE_COMMAND', 'DIREXTALK_CLAUDE_CODE_COMMAND', 'DIREXTALK_CLAUDE_COMMAND') @('claude.exe', 'claude.cmd', 'claude', 'claude-code.exe', 'claude-code.cmd', 'claude-code')
Set-AgentCommandIfMissing @('DIREXTALK_GEMINI_COMMAND') @('gemini.exe', 'gemini.cmd', 'gemini')
Set-AgentCommandIfMissing @('DIREXTALK_COPILOT_COMMAND') @('copilot.exe', 'copilot.cmd', 'copilot')
Set-AgentCommandIfMissing @('DIREXTALK_DEVIN_COMMAND') @('devin.exe', 'devin.cmd', 'devin')
Set-AgentCommandIfMissing @('DIREXTALK_KIMI_COMMAND') @('kimi.exe', 'kimi.cmd', 'kimi')
Set-OpenCodeCommandIfMissing
Set-AgentCommandIfMissing @('DIREXTALK_IFLOW_COMMAND') @('iflow.exe', 'iflow.cmd', 'iflow')
Set-AgentCommandIfMissing @('DIREXTALK_QODER_COMMAND', 'DIREXTALK_QODERCLI_COMMAND') @('qodercli.exe', 'qodercli.cmd', 'qodercli', 'qoder.exe', 'qoder.cmd', 'qoder')
Set-AgentCommandIfMissing @('DIREXTALK_PI_COMMAND') @('pi.exe', 'pi.cmd', 'pi')
Set-AgentCommandIfMissing @('DIREXTALK_ANTIGRAVITY_COMMAND', 'DIREXTALK_AGY_COMMAND') @('agy.exe', 'agy.cmd', 'agy')
Set-AgentCommandIfMissing @('DIREXTALK_OPENCLAW_COMMAND') @('openclaw.exe', 'openclaw.cmd', 'openclaw')
Set-AgentCommandIfMissing @('DIREXTALK_HERMES_COMMAND') @('hermes.exe', 'hermes.cmd', 'hermes')

$repoRootForBash = ConvertTo-GitBashPath $RepoRoot
$quotedArgs = ($OrchestrateArgs | ForEach-Object { Quote-BashArg $_ }) -join ' '
$command = "cd $(Quote-BashArg $repoRootForBash) && ./scripts/orchestrate.sh $quotedArgs"

$releaseNetworkSnapshot = Get-DirextalkReleaseNetworkInputSnapshot
$exitCode = 1
try {
  Set-DirextalkReleaseNetworkInputs
  & $bash -lc $command
  $exitCode = $LASTEXITCODE
}
finally {
  Restore-DirextalkReleaseNetworkInputSnapshot $releaseNetworkSnapshot
}
exit $exitCode
