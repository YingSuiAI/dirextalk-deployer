param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $DestroyArgs
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'lib\windows-paths.ps1')
. (Join-Path $ScriptDir 'lib\windows-bash.ps1')

function Quote-BashArg([string] $Value) {
  return "'" + ($Value -replace "'", "'\''") + "'"
}

$bash = Resolve-DirextalkBashCommand

$windowsDirextalkHome = Resolve-WindowsDirextalkHome
$env:DIREXTALK_WINDOWS_HOME = $windowsDirextalkHome
$env:DIREXTALK_HOME = $windowsDirextalkHome.Replace('\', '/')
$env:DIREXTALK_LOCAL_PATH_STYLE = 'windows'

if ($env:DIREXTALK_WORKDIR) {
  $env:DIREXTALK_WORKDIR_WINDOWS = $env:DIREXTALK_WORKDIR
  $env:DIREXTALK_WORKDIR = ([IO.Path]::GetFullPath($env:DIREXTALK_WORKDIR)).Replace('\', '/')
}

$repoRootForBash = ConvertTo-GitBashPath $RepoRoot
$quotedArgs = ($DestroyArgs | ForEach-Object { Quote-BashArg (Convert-ArgumentForGitBash $_) }) -join ' '
$command = "cd $(Quote-BashArg $repoRootForBash) && ./scripts/destroy.sh $quotedArgs"

& $bash -lc $command
exit $LASTEXITCODE
