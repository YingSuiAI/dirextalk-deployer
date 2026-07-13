function Test-DirextalkBashCommand([string] $Candidate) {
  if (-not $Candidate) { return $false }
  try {
    $global:LASTEXITCODE = 0
    $probe = (& $Candidate --noprofile --norc -lc 'printf dirextalk-bash-ok' 2>$null | Out-String).Trim()
    return $LASTEXITCODE -eq 0 -and $probe -eq 'dirextalk-bash-ok'
  }
  catch {
    return $false
  }
}

function Resolve-DirextalkBashCommand {
  if ($env:DIREXTALK_BASH_COMMAND) {
    $explicit = $env:DIREXTALK_BASH_COMMAND
    if (Test-DirextalkBashCommand $explicit) { return $explicit }
    throw "DIREXTALK_BASH_COMMAND is not a working POSIX Bash command."
  }

  $windows = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\') + '\'
  $windowsApps = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')).TrimEnd('\') + '\'
  foreach ($command in @(Get-Command -Name @('bash.exe', 'bash') -All -ErrorAction SilentlyContinue)) {
    $source = $command.Source
    if (-not $source) { continue }
    $full = [IO.Path]::GetFullPath($source)
    if ($full.StartsWith($windows, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($windowsApps, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-DirextalkBashCommand $full) { return $full }
  }

  foreach ($candidate in @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin\bash.exe"
  )) {
    if ($candidate -and (Test-Path -LiteralPath $candidate) -and (Test-DirextalkBashCommand $candidate)) {
      return $candidate
    }
  }
  throw "A working Git for Windows or MSYS2 Bash was not found. Add it to PATH or set DIREXTALK_BASH_COMMAND."
}
