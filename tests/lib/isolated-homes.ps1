$script:DirextalkTestHomeEnvironmentNames = @(
  'HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA',
  'XDG_CONFIG_HOME', 'DIREXTALK_HOME', 'ACP_HOME', 'ANTIGRAVITY_HOME', 'AGY_HOME',
  'HERMES_HOME', 'CODEX_HOME', 'CLAUDE_HOME', 'CLAUDECODE_HOME', 'GEMINI_HOME',
  'CURSOR_HOME', 'COPILOT_HOME', 'DEVIN_HOME', 'IFLOW_HOME', 'KIMI_HOME',
  'OPENCODE_HOME', 'OPEN_CODE_HOME', 'PI_CODING_AGENT_DIR', 'PI_HOME', 'QODER_HOME',
  'REASONIX_HOME', 'TMUX_HOME', 'OPENCLAW_HOME'
)

function Assert-DirextalkTestPathUnderRoot([string] $Path, [string] $Root, [string] $Label) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  if ($fullPath -ne $fullRoot -and
      -not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label escaped test root: $fullPath (root=$fullRoot)"
  }
}

function Assert-DirextalkTestHomes([string] $Root) {
  foreach ($name in $script:DirextalkTestHomeEnvironmentNames) {
    if ($name -in @('HOMEDRIVE', 'HOMEPATH')) { continue }
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not $value) { throw "$name must be set before running an isolated runtime test" }
    Assert-DirextalkTestPathUnderRoot $value $Root $name
  }
  Assert-DirextalkTestPathUnderRoot "$env:HOMEDRIVE$env:HOMEPATH" $Root 'HOMEDRIVE+HOMEPATH'
}

function Set-DirextalkTestHomes([string] $Root) {
  $fullRoot = [IO.Path]::GetFullPath($Root)
  $testHome = Join-Path $fullRoot 'home'
  $drive = [IO.Path]::GetPathRoot($testHome).TrimEnd('\')
  $homePath = $testHome.Substring([IO.Path]::GetPathRoot($testHome).Length - 1)

  $env:HOME = $testHome
  $env:USERPROFILE = $testHome
  $env:HOMEDRIVE = $drive
  $env:HOMEPATH = $homePath
  $env:APPDATA = Join-Path $fullRoot 'appdata'
  $env:LOCALAPPDATA = Join-Path $fullRoot 'localappdata'
  $env:XDG_CONFIG_HOME = Join-Path $fullRoot 'xdg'
  $env:DIREXTALK_HOME = Join-Path $testHome '.dirextalk'

  foreach ($name in $script:DirextalkTestHomeEnvironmentNames) {
    if ($name -in @('HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'DIREXTALK_HOME')) { continue }
    [Environment]::SetEnvironmentVariable($name, (Join-Path $fullRoot "runtime-homes\$($name.ToLowerInvariant())"), 'Process')
  }

  foreach ($name in $script:DirextalkTestHomeEnvironmentNames) {
    if ($name -in @('HOMEDRIVE', 'HOMEPATH')) { continue }
    New-Item -ItemType Directory -Force -Path ([Environment]::GetEnvironmentVariable($name, 'Process')) | Out-Null
  }
  Assert-DirextalkTestHomes $fullRoot
}
