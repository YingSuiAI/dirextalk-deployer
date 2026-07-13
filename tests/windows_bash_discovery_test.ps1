$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows bash discovery test skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\lib\windows-bash.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dirextalk-bash-discovery-' + [Guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH
$savedOverride = $env:DIREXTALK_BASH_COMMAND
try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $fake = Join-Path $temp 'bash.ps1'
  [IO.File]::WriteAllText($fake, "Write-Output 'dirextalk-bash-ok'`n", [Text.Encoding]::ASCII)

  $env:DIREXTALK_BASH_COMMAND = $fake
  if ((Resolve-DirextalkBashCommand) -ne $fake) { throw 'explicit Bash override was not selected' }

  Remove-Item Env:DIREXTALK_BASH_COMMAND
  $env:PATH = "$temp;$savedPath"
  if ((Resolve-DirextalkBashCommand) -ne $fake) { throw 'working Bash on PATH was not selected' }

  $env:DIREXTALK_BASH_COMMAND = (Join-Path $temp 'missing-bash.exe')
  try {
    Resolve-DirextalkBashCommand | Out-Null
    throw 'invalid explicit Bash override was accepted'
  }
  catch {
    if ($_.Exception.Message -eq 'invalid explicit Bash override was accepted') { throw }
  }
}
finally {
  $env:PATH = $savedPath
  [Environment]::SetEnvironmentVariable('DIREXTALK_BASH_COMMAND', $savedOverride, 'Process')
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'windows bash discovery test ok'
