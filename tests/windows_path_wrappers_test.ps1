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

$oldDirexioHome = $env:DIREXIO_HOME
$oldUserProfile = $env:USERPROFILE
try {
  Assert-Equal (ConvertTo-GitBashPath 'C:\Users\deploy\.direxio') '/c/Users/deploy/.direxio' 'Windows paths convert to Git Bash paths'
  Assert-Equal (ConvertTo-GitBashPath 'C:/Users/deploy/.direxio') '/c/Users/deploy/.direxio' 'Slash-normalized Windows paths convert to Git Bash paths'
  Assert-Equal (ConvertTo-GitBashPath '/c/Users/deploy/.direxio') '/c/Users/deploy/.direxio' 'Existing Git Bash paths are not converted twice'
  Assert-Equal (ConvertTo-GitBashPath '/mnt/c/Users/deploy/.direxio') '/c/Users/deploy/.direxio' 'WSL mount paths normalize to Git Bash drive paths'

  $env:USERPROFILE = 'C:\Users\deploy'
  $env:DIREXIO_HOME = '/c/Users/deploy/.direxio'
  Assert-Equal (Resolve-WindowsDirexioHome) 'C:\Users\deploy\.direxio' 'POSIX DIREXIO_HOME from a previous wrapper run falls back to native USERPROFILE'
  $env:DIREXIO_HOME = '/cygdrive/c/Users/deploy/.direxio'
  Assert-Equal (Resolve-WindowsDirexioHome) 'C:\Users\deploy\.direxio' 'Cygwin DIREXIO_HOME from a previous wrapper run falls back to native USERPROFILE'

  $env:DIREXIO_HOME = 'D:\custom\.direxio'
  Assert-Equal (Resolve-WindowsDirexioHome) 'D:\custom\.direxio' 'Native DIREXIO_HOME override is preserved'

  Assert-Equal (Convert-ArgumentForGitBash 'C:\Users\deploy\.direxio\nodes\q4\state.json') '/c/Users/deploy/.direxio/nodes/q4/state.json' 'Explicit Windows state path arguments convert'
  Assert-Equal (Convert-ArgumentForGitBash '/c/Users/deploy/.direxio/nodes/q4/state.json') '/c/Users/deploy/.direxio/nodes/q4/state.json' 'Explicit Git Bash state path arguments pass through'
  Assert-Equal (Convert-ArgumentForGitBash '/mnt/c/Users/deploy/.direxio/nodes/q4/state.json') '/c/Users/deploy/.direxio/nodes/q4/state.json' 'Explicit WSL state path arguments normalize to Git Bash paths'
}
finally {
  $env:DIREXIO_HOME = $oldDirexioHome
  $env:USERPROFILE = $oldUserProfile
}

Write-Output 'windows path wrapper test ok'
