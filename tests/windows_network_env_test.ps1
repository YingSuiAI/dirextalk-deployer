$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows network environment test skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\lib\windows-network-env.ps1')

$names = @(
  'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY',
  'DIREXTALK_RELEASE_HTTP_PROXY_INPUT',
  'DIREXTALK_RELEASE_HTTPS_PROXY_INPUT', 'DIREXTALK_RELEASE_NO_PROXY_INPUT'
)
$saved = @{}
foreach ($name in $names) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://proxy.test:8080', 'Process')
  [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.test:8443', 'Process')
  [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1', 'Process')
  [Environment]::SetEnvironmentVariable('DIREXTALK_RELEASE_HTTP_PROXY_INPUT', $null, 'Process')
  [Environment]::SetEnvironmentVariable('DIREXTALK_RELEASE_HTTPS_PROXY_INPUT', $null, 'Process')
  [Environment]::SetEnvironmentVariable('DIREXTALK_RELEASE_NO_PROXY_INPUT', $null, 'Process')

  Set-DirextalkReleaseNetworkInputs

  foreach ($pair in @(
    @('DIREXTALK_RELEASE_HTTP_PROXY_INPUT', 'http://proxy.test:8080'),
    @('DIREXTALK_RELEASE_HTTPS_PROXY_INPUT', 'http://proxy.test:8443'),
    @('DIREXTALK_RELEASE_NO_PROXY_INPUT', 'localhost,127.0.0.1')
  )) {
    if ([Environment]::GetEnvironmentVariable($pair[0], 'Process') -ne $pair[1]) {
      throw "$($pair[0]) was not copied without alteration"
    }
  }

  [Environment]::SetEnvironmentVariable('DIREXTALK_RELEASE_HTTP_PROXY_INPUT', 'http://override.test:8080', 'Process')
  Set-DirextalkReleaseNetworkInputs
  if ([Environment]::GetEnvironmentVariable('DIREXTALK_RELEASE_HTTP_PROXY_INPUT', 'Process') -ne 'http://override.test:8080') {
    throw 'An explicit release proxy input must not be overwritten'
  }

  $snapshot = Get-DirextalkReleaseNetworkInputSnapshot
  [Environment]::SetEnvironmentVariable('DIREXTALK_RELEASE_HTTP_PROXY_INPUT', 'http://temporary.test:8080', 'Process')
  Restore-DirextalkReleaseNetworkInputSnapshot $snapshot
  if ([Environment]::GetEnvironmentVariable('DIREXTALK_RELEASE_HTTP_PROXY_INPUT', 'Process') -ne 'http://override.test:8080') {
    throw 'Release proxy inputs must be restored after invoking Git Bash'
  }

  $gitBash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $gitBash) { throw 'Git Bash is required for the Windows deployment wrapper' }
  & $gitBash --noprofile --norc -c 'test -n "$DIREXTALK_RELEASE_HTTP_PROXY_INPUT" && test -n "$DIREXTALK_RELEASE_HTTPS_PROXY_INPUT"'
  if ($LASTEXITCODE -ne 0) { throw 'Git Bash did not receive the private release proxy transport variables' }
}
finally {
  foreach ($name in $names) {
    [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
  }
}

Write-Output 'windows network environment test ok'
