$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows recommendation test skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\lib\windows-paths.ps1')
. (Join-Path $root 'tests\lib\isolated-homes.ps1')

function Quote-BashArg([string] $Value) {
  return "'" + ($Value -replace "'", "'\''") + "'"
}

function Assert-Contains([string] $Actual, [string] $Expected, [string] $Message) {
  if (-not $Actual.Contains($Expected)) {
    throw "$Message; expected to contain '$Expected', got '$Actual'"
  }
}

$gitBashCandidates = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "$env:ProgramFiles\Git\usr\bin\bash.exe",
  "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
$gitBash = $gitBashCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $gitBash) {
  throw 'Git Bash is required for the native Windows recommendation test'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("dirextalk-windows-recommendation-" + [Guid]::NewGuid().ToString('N'))
$sentinelRoot = Join-Path ([IO.Path]::GetTempPath()) ('dirextalk-user-sentinel-' + [Guid]::NewGuid().ToString('N'))
$envNames = @($script:DirextalkTestHomeEnvironmentNames + @('DIREXTALK_LOCAL_PATH_STYLE', 'PATH') | Select-Object -Unique)
$savedEnv = @{}
foreach ($name in $envNames) {
  $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  New-Item -ItemType Directory -Force -Path $temp, $sentinelRoot | Out-Null
  Set-DirextalkTestHomes $temp
  $testHome = $env:USERPROFILE
  $fakeBin = Join-Path $temp 'fake-bin'
  $serviceDir = Join-Path $testHome '.dirextalk\nodes\service.example.test'
  $runtimeDir = Join-Path $serviceDir 'dirextalk-connect'
  $connect = Join-Path $runtimeDir 'dirextalk-connect.cmd'
  $config = Join-Path $runtimeDir 'config.toml'
  $callLog = Join-Path $temp 'calls.log'
  $sentinel = Join-Path $sentinelRoot 'openclaw.json'

  New-Item -ItemType Directory -Force -Path $fakeBin, $runtimeDir | Out-Null
  Set-Content -LiteralPath $config -Value '# fake config' -Encoding utf8NoBOM
  Set-Content -LiteralPath $sentinel -Value '{"keep":true}' -Encoding utf8NoBOM
  $sentinelBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash

  $escapedLog = $callLog -replace '%', '%%'
  Set-Content -LiteralPath (Join-Path $fakeBin 'npm.cmd') -Encoding ascii -Value @(
    '@echo off',
    "echo npm %*>>`"$escapedLog`"",
    'exit /b 0'
  )
  Set-Content -LiteralPath $connect -Encoding ascii -Value @(
    '@echo off',
    "echo connect %*>>`"$escapedLog`"",
    'exit /b 0'
  )

  $env:DIREXTALK_LOCAL_PATH_STYLE = 'windows'
  $env:PATH = "$fakeBin;$($savedEnv['PATH'])"
  Assert-DirextalkTestHomes $temp

  $rootBash = ConvertTo-GitBashPath $root
  $connectBash = ConvertTo-GitBashPath $connect
  $configBash = ConvertTo-GitBashPath $config
  $serviceDirBash = ConvertTo-GitBashPath $serviceDir
  $bashCommand = @(
    "source $(Quote-BashArg "$rootBash/scripts/phases/s6_wire_local.sh")",
    "DIREXTALK_LOCAL_PATH_STYLE=windows _connect_install_command $(Quote-BashArg $connectBash) $(Quote-BashArg $configBash) service.example.test $(Quote-BashArg $serviceDirBash)"
  ) -join '; '

  $recommendation = (& $gitBash -lc $bashCommand | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Git Bash recommendation generation failed with exit code $LASTEXITCODE"
  }
  Assert-Contains $recommendation 'Test-Path -LiteralPath' 'Windows recommendation must use PowerShell syntax'
  Assert-Contains $recommendation 'npm install --prefix' 'Windows recommendation must install in the service scope'
  if ($recommendation.Contains('/mnt/') -or $recommendation.Contains('if [ -x')) {
    throw "Windows recommendation leaked a POSIX consumer path or Bash syntax: $recommendation"
  }

  & ([ScriptBlock]::Create($recommendation))
  if ($LASTEXITCODE -ne 0) {
    throw "generated PowerShell recommendation failed with exit code $LASTEXITCODE"
  }

  $calls = Get-Content -Raw -LiteralPath $callLog
  Assert-Contains $calls 'npm install --prefix' 'fake npm must receive the service-scoped install'
  Assert-Contains $calls 'connect daemon stop --service-name service.example.test' 'existing daemon stop command must run'
  Assert-Contains $calls 'connect daemon install --config' 'daemon install command must run'
  Assert-Contains $calls '--service-name service.example.test --force' 'daemon install must preserve service identity'

  $sentinelAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash
  if ($sentinelAfter -ne $sentinelBefore) {
    throw 'native Windows recommendation test modified the sentinel user config'
  }
}
finally {
  foreach ($name in $envNames) {
    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
  }
  foreach ($candidate in @($temp, $sentinelRoot)) {
    $resolved = [IO.Path]::GetFullPath($candidate)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -match '^dirextalk-(windows-recommendation|user-sentinel)') {
      Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Output 'windows recommendation test ok'
