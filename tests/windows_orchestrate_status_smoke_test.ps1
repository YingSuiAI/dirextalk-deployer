$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows orchestrate status smoke skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tests\lib\isolated-homes.ps1')
. (Join-Path $root 'scripts\lib\windows-bash.ps1')
$bashCommand = Resolve-DirextalkBashCommand
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$temp = Join-Path ([IO.Path]::GetTempPath()) ("dirextalk-windows-status O'Brien-" + [Guid]::NewGuid().ToString('N'))
$sentinelRoot = Join-Path ([IO.Path]::GetTempPath()) ('dirextalk-user-sentinel-' + [Guid]::NewGuid().ToString('N'))
$extraEnvNames = @(
  'DIREXTALK_WORKDIR',
  'DIREXTALK_WORKDIR_WINDOWS',
  'DIREXTALK_LOCAL_PATH_STYLE',
  'DIREXTALK_BASH_COMMAND',
  'DIREXTALK_AGENT_WORKSPACE',
  'DIREXTALK_AGENT_WORKSPACE_WINDOWS'
)
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
  [IO.File]::WriteAllText($sentinel, '{"keep":true}', $utf8NoBom)
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
  [IO.File]::WriteAllText((Join-Path $workdir 'state.json'), ($state | ConvertTo-Json -Depth 8), $utf8NoBom)
  $env:DIREXTALK_WORKDIR = $workdir
  $env:DIREXTALK_BASH_COMMAND = $bashCommand
  $env:DIREXTALK_AGENT_WORKSPACE = $null
  $env:DIREXTALK_AGENT_WORKSPACE_WINDOWS = Join-Path $temp 'legacy implicit workspace'
  Assert-DirextalkTestHomes $temp

  $output = (& (Join-Path $root 'scripts\orchestrate.ps1') status 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { throw "orchestrate.ps1 status failed with exit code $LASTEXITCODE`n$output" }
  if ($env:DIREXTALK_AGENT_WORKSPACE_WINDOWS) {
    throw "orchestrate.ps1 must not use the caller's current directory as the implicit agent workspace; got '$env:DIREXTALK_AGENT_WORKSPACE_WINDOWS'"
  }
  $expected = "`$env:DOMAIN = 'status.example.test'; & '.\scripts\destroy.ps1'"
  if (-not $output.Contains($expected)) {
    throw "Windows recovery output must use the PowerShell renderer; expected '$expected'`n$output"
  }
  if ($output.Contains(' bash ') -or $output.Contains('/scripts/destroy.sh')) {
    throw "Windows recovery output leaked a Bash command`n$output"
  }
  $sentinelAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash
  if ($sentinelAfter -ne $sentinelBefore) { throw 'orchestrate.ps1 status modified the external user-config sentinel' }

  $explicitWorkspace = Join-Path $temp 'explicit agent workspace'
  $env:DIREXTALK_AGENT_WORKSPACE = $explicitWorkspace
  $explicitOutput = (& (Join-Path $root 'scripts\orchestrate.ps1') status 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { throw "orchestrate.ps1 status with explicit workspace failed with exit code $LASTEXITCODE`n$explicitOutput" }
  if ($env:DIREXTALK_AGENT_WORKSPACE -ne $explicitWorkspace) {
    throw 'orchestrate.ps1 must preserve an explicit DIREXTALK_AGENT_WORKSPACE override'
  }
  if ($env:DIREXTALK_AGENT_WORKSPACE_WINDOWS) {
    throw 'orchestrate.ps1 must not synthesize DIREXTALK_AGENT_WORKSPACE_WINDOWS when an explicit workspace is set'
  }
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
