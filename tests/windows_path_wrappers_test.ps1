$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows path wrapper test skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\lib\windows-paths.ps1')
. (Join-Path $root 'tests\lib\isolated-homes.ps1')

function Assert-Equal([string] $Actual, [string] $Expected, [string] $Message) {
  if ($Actual -ne $Expected) {
    throw "$Message; expected '$Expected', got '$Actual'"
  }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('dirextalk-windows-paths-' + [Guid]::NewGuid().ToString('N'))
$savedEnv = @{}
foreach ($name in $script:DirextalkTestHomeEnvironmentNames) {
  $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  Set-DirextalkTestHomes $temp
  Assert-Equal (ConvertTo-GitBashPath 'C:\Users\deploy\.dirextalk') '/c/Users/deploy/.dirextalk' 'Windows paths convert to Git Bash paths'
  Assert-Equal (ConvertTo-GitBashPath 'C:/Users/deploy/.dirextalk') '/c/Users/deploy/.dirextalk' 'Slash-normalized Windows paths convert to Git Bash paths'
  Assert-Equal (ConvertTo-GitBashPath '/c/Users/deploy/.dirextalk') '/c/Users/deploy/.dirextalk' 'Existing Git Bash paths are not converted twice'
  Assert-Equal (ConvertTo-GitBashPath '/mnt/c/Users/deploy/.dirextalk') '/c/Users/deploy/.dirextalk' 'WSL mount paths normalize to Git Bash drive paths'

  $expectedHome = Join-Path $env:USERPROFILE '.dirextalk'
  $env:DIREXTALK_HOME = ConvertTo-GitBashPath $expectedHome
  Assert-Equal (Resolve-WindowsDirextalkHome) $expectedHome 'POSIX DIREXTALK_HOME from a previous wrapper run falls back to native USERPROFILE'
  $env:DIREXTALK_HOME = (ConvertTo-GitBashPath $expectedHome).Replace('/c/', '/cygdrive/c/')
  Assert-Equal (Resolve-WindowsDirextalkHome) $expectedHome 'Cygwin DIREXTALK_HOME from a previous wrapper run falls back to native USERPROFILE'

  $nativeOverride = Join-Path $temp 'custom\.dirextalk'
  $env:DIREXTALK_HOME = $nativeOverride
  Assert-Equal (Resolve-WindowsDirextalkHome) $nativeOverride 'Native DIREXTALK_HOME override is preserved'
  Assert-DirextalkTestHomes $temp

  Assert-Equal (Convert-ArgumentForGitBash 'C:\Users\deploy\.dirextalk\nodes\q4\state.json') '/c/Users/deploy/.dirextalk/nodes/q4/state.json' 'Explicit Windows state path arguments convert'
  Assert-Equal (Convert-ArgumentForGitBash '/c/Users/deploy/.dirextalk/nodes/q4/state.json') '/c/Users/deploy/.dirextalk/nodes/q4/state.json' 'Explicit Git Bash state path arguments pass through'
  Assert-Equal (Convert-ArgumentForGitBash '/mnt/c/Users/deploy/.dirextalk/nodes/q4/state.json') '/c/Users/deploy/.dirextalk/nodes/q4/state.json' 'Explicit WSL state path arguments normalize to Git Bash paths'
}
finally {
  foreach ($name in $script:DirextalkTestHomeEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
  }
  $resolved = [IO.Path]::GetFullPath($temp)
  $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolved).StartsWith('dirextalk-windows-paths-', [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Output 'windows path wrapper test ok'
