function Copy-DirextalkReleaseNetworkInput([string] $Source, [string] $Destination) {
  $existing = [Environment]::GetEnvironmentVariable($Destination, 'Process')
  if ($null -ne $existing) {
    return
  }
  $value = [Environment]::GetEnvironmentVariable($Source, 'Process')
  if ($null -ne $value) {
    [Environment]::SetEnvironmentVariable($Destination, $value, 'Process')
  }
}

function Set-DirextalkReleaseNetworkInputs {
  # Git for Windows omits standard proxy variables from Bash. Copy them to
  # private transport variables without printing them; aws.sh consumes and
  # clears these values before any child process is started.
  Copy-DirextalkReleaseNetworkInput 'HTTP_PROXY' 'DIREXTALK_RELEASE_HTTP_PROXY_INPUT'
  Copy-DirextalkReleaseNetworkInput 'HTTPS_PROXY' 'DIREXTALK_RELEASE_HTTPS_PROXY_INPUT'
  Copy-DirextalkReleaseNetworkInput 'NO_PROXY' 'DIREXTALK_RELEASE_NO_PROXY_INPUT'
}

function Get-DirextalkReleaseNetworkInputSnapshot {
  $snapshot = @{}
  foreach ($name in @(
    'DIREXTALK_RELEASE_HTTP_PROXY_INPUT',
    'DIREXTALK_RELEASE_HTTPS_PROXY_INPUT',
    'DIREXTALK_RELEASE_NO_PROXY_INPUT'
  )) {
    $snapshot[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  return $snapshot
}

function Restore-DirextalkReleaseNetworkInputSnapshot([hashtable] $Snapshot) {
  foreach ($name in $Snapshot.Keys) {
    [Environment]::SetEnvironmentVariable($name, $Snapshot[$name], 'Process')
  }
}
