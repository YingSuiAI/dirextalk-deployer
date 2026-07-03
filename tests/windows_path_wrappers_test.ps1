$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows path wrapper test skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\lib\windows-paths.ps1')

function Assert-Equal([string] $Actual, [string] $Expected, [string] $Message) {
  if ($Actual -ne $Expected) {
    throw "$Message; expected '$Expected', got '$Actual'"
  }
}

$oldDirextalkHome = $env:DIREXTALK_HOME
$oldUserProfile = $env:USERPROFILE
try {
  Assert-Equal (ConvertTo-GitBashPath 'C:\Users\deploy\.dirextalk') '/c/Users/deploy/.dirextalk' 'Windows paths convert to Git Bash paths'
  Assert-Equal (ConvertTo-GitBashPath 'C:/Users/deploy/.dirextalk') '/c/Users/deploy/.dirextalk' 'Slash-normalized Windows paths convert to Git Bash paths'
  Assert-Equal (ConvertTo-GitBashPath '/c/Users/deploy/.dirextalk') '/c/Users/deploy/.dirextalk' 'Existing Git Bash paths are not converted twice'
  Assert-Equal (ConvertTo-GitBashPath '/mnt/c/Users/deploy/.dirextalk') '/c/Users/deploy/.dirextalk' 'WSL mount paths normalize to Git Bash drive paths'

  $env:USERPROFILE = 'C:\Users\deploy'
  $env:DIREXTALK_HOME = '/c/Users/deploy/.dirextalk'
  Assert-Equal (Resolve-WindowsDirextalkHome) 'C:\Users\deploy\.dirextalk' 'POSIX DIREXTALK_HOME from a previous wrapper run falls back to native USERPROFILE'
  $env:DIREXTALK_HOME = '/cygdrive/c/Users/deploy/.dirextalk'
  Assert-Equal (Resolve-WindowsDirextalkHome) 'C:\Users\deploy\.dirextalk' 'Cygwin DIREXTALK_HOME from a previous wrapper run falls back to native USERPROFILE'

  $env:DIREXTALK_HOME = 'D:\custom\.dirextalk'
  Assert-Equal (Resolve-WindowsDirextalkHome) 'D:\custom\.dirextalk' 'Native DIREXTALK_HOME override is preserved'

  Assert-Equal (Convert-ArgumentForGitBash 'C:\Users\deploy\.dirextalk\nodes\q4\state.json') '/c/Users/deploy/.dirextalk/nodes/q4/state.json' 'Explicit Windows state path arguments convert'
  Assert-Equal (Convert-ArgumentForGitBash '/c/Users/deploy/.dirextalk/nodes/q4/state.json') '/c/Users/deploy/.dirextalk/nodes/q4/state.json' 'Explicit Git Bash state path arguments pass through'
  Assert-Equal (Convert-ArgumentForGitBash '/mnt/c/Users/deploy/.dirextalk/nodes/q4/state.json') '/c/Users/deploy/.dirextalk/nodes/q4/state.json' 'Explicit WSL state path arguments normalize to Git Bash paths'
}
finally {
  $env:DIREXTALK_HOME = $oldDirextalkHome
  $env:USERPROFILE = $oldUserProfile
}

Write-Output 'windows path wrapper test ok'
