$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows orchestrate status smoke skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\lib\isolated-homes.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ("dirextalk-windows-status O'Brien-" + [Guid]::NewGuid().ToString('N'))
$sentinelRoot = Join-Path ([IO.Path]::GetTempPath()) ('dirextalk-user-sentinel-' + [Guid]::NewGuid().ToString('N'))
$extraEnvNames = @('DIREXTALK_WORKDIR', 'DIREXTALK_WORKDIR_WINDOWS', 'DIREXTALK_LOCAL_PATH_STYLE')
$envNames = @($script:DirextalkTestHomeEnvironmentNames + $extraEnvNames | Select-Object -Unique)
$savedEnv = @{}
foreach ($name in $envNames) {
  $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  New-Item -ItemType Directory -Force -Path $temp, $sentinelRoot | Out-Null
  Set-DirextalkTestHomes $temp
  $workdir = Join-Path $temp "state O'Brien"
  New-Item -ItemType Directory -Force -Path $workdir | Out-Null
  $sentinel = Join-Path $sentinelRoot 'openclaw.json'
  Set-Content -LiteralPath $sentinel -Value '{"keep":true}' -Encoding utf8NoBOM
  $sentinelBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash

  $state = @{
    run_id = 'windows-status-smoke'
    domain = 'status.example.test'
    phase = 'S4_BOOTSTRAP_STACK'
    phases = @{
      S0_PREREQ_AWS = @{ status = 'done' }
      S1_PREFLIGHT = @{ status = 'done' }
      S2_DOMAIN = @{ status = 'done' }
      S3_PROVISION = @{ status = 'done' }
      S4_BOOTSTRAP_STACK = @{ status = 'failed' }
      S5_INIT_TOKENS = @{ status = 'pending' }
      S6_WIRE_LOCAL = @{ status = 'pending' }
      S7_VERIFY_E2E = @{ status = 'pending' }
    }
    resources = @{ instance_id = 'i-windows-smoke' }
  }
  $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $workdir 'state.json') -Encoding utf8NoBOM
  $env:DIREXTALK_WORKDIR = $workdir
  Assert-DirextalkTestHomes $temp

  $output = (& (Join-Path $root 'scripts\orchestrate.ps1') status 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { throw "orchestrate.ps1 status failed with exit code $LASTEXITCODE`n$output" }
  $expected = "`$env:DOMAIN = 'status.example.test'; & '.\scripts\destroy.ps1'"
  if (-not $output.Contains($expected)) {
    throw "Windows recovery output must use the PowerShell renderer; expected '$expected'`n$output"
  }
  if ($output.Contains(' bash ') -or $output.Contains('/scripts/destroy.sh')) {
    throw "Windows recovery output leaked a Bash command`n$output"
  }
  $sentinelAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash
  if ($sentinelAfter -ne $sentinelBefore) { throw 'orchestrate.ps1 status modified the external user-config sentinel' }
}
finally {
  foreach ($name in $envNames) {
    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
  }
  foreach ($candidate in @($temp, $sentinelRoot)) {
    $resolved = [IO.Path]::GetFullPath($candidate)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -match '^dirextalk-(windows-status|user-sentinel)') {
      Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Output 'windows orchestrate status smoke ok'
