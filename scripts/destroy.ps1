param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $DestroyArgs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'lib\windows-paths.ps1')

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
  throw "Git Bash was not found. Install Git for Windows or run scripts/destroy.sh from a POSIX shell."
}

function Quote-BashArg([string] $Value) {
  return "'" + ($Value -replace "'", "'\''") + "'"
}

$bash = Find-GitBash

$windowsDirextalkHome = Resolve-WindowsDirextalkHome
$env:DIREXTALK_WINDOWS_HOME = $windowsDirextalkHome
$env:DIREXTALK_HOME = ConvertTo-GitBashPath $windowsDirextalkHome
$env:DIREXTALK_LOCAL_PATH_STYLE = 'windows'

if ($env:DIREXTALK_WORKDIR) {
  $env:DIREXTALK_WORKDIR_WINDOWS = $env:DIREXTALK_WORKDIR
  $env:DIREXTALK_WORKDIR = ConvertTo-GitBashPath $env:DIREXTALK_WORKDIR
}

$repoRootForBash = ConvertTo-GitBashPath $RepoRoot
$quotedArgs = ($DestroyArgs | ForEach-Object { Quote-BashArg (Convert-ArgumentForGitBash $_) }) -join ' '
$command = "cd $(Quote-BashArg $repoRootForBash) && ./scripts/destroy.sh $quotedArgs"

& $bash -lc $command
exit $LASTEXITCODE
