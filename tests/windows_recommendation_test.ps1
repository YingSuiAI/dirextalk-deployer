$ErrorActionPreference = 'Stop'

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  Write-Output 'windows recommendation test skipped on non-Windows host'
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\lib\windows-paths.ps1')

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
$envNames = @('HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'DIREXTALK_HOME', 'DIREXTALK_LOCAL_PATH_STYLE', 'PATH')
$savedEnv = @{}
foreach ($name in $envNames) {
  $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  $testHome = Join-Path $temp 'home'
  $fakeBin = Join-Path $temp 'fake-bin'
  $serviceDir = Join-Path $testHome '.dirextalk\nodes\service.example.test'
  $runtimeDir = Join-Path $serviceDir 'dirextalk-connect'
  $connect = Join-Path $runtimeDir 'dirextalk-connect.cmd'
  $config = Join-Path $runtimeDir 'config.toml'
  $callLog = Join-Path $temp 'calls.log'
  $sentinel = Join-Path $temp 'sentinel-user-config\openclaw.json'

  New-Item -ItemType Directory -Force -Path $testHome, $fakeBin, $runtimeDir, (Split-Path -Parent $sentinel) | Out-Null
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

  $env:HOME = $testHome
  $env:USERPROFILE = $testHome
  $env:HOMEDRIVE = [IO.Path]::GetPathRoot($testHome).TrimEnd('\')
  $env:HOMEPATH = $testHome.Substring([IO.Path]::GetPathRoot($testHome).Length - 1)
  $env:APPDATA = Join-Path $temp 'appdata'
  $env:LOCALAPPDATA = Join-Path $temp 'localappdata'
  $env:XDG_CONFIG_HOME = Join-Path $temp 'xdg'
  $env:DIREXTALK_HOME = Join-Path $testHome '.dirextalk'
  $env:DIREXTALK_LOCAL_PATH_STYLE = 'windows'
  $env:PATH = "$fakeBin;$($savedEnv['PATH'])"

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
  $resolvedTemp = [IO.Path]::GetFullPath($temp)
  $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedTemp).StartsWith('dirextalk-windows-recommendation-', [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Output 'windows recommendation test ok'
