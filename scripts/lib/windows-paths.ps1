function ConvertTo-GitBashPath([string] $Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $Path
  }

  $normalized = $Path.Replace('\', '/')
  if ($normalized -match '^/[A-Za-z](/|$)') {
    return $normalized
  }
  if ($normalized -match '^/mnt/[A-Za-z](/|$)') {
    $drive = $normalized.Substring(5, 1).ToLowerInvariant()
    $rest = $normalized.Substring(6)
    return "/$drive$rest"
  }
  if ($normalized -match '^/cygdrive/[A-Za-z](/|$)') {
    $drive = $normalized.Substring(10, 1).ToLowerInvariant()
    $rest = $normalized.Substring(11)
    return "/$drive$rest"
  }
  if ($normalized -match '^[A-Za-z]:/') {
    $drive = $normalized.Substring(0, 1).ToLowerInvariant()
    $rest = $normalized.Substring(2)
    return "/$drive$rest"
  }

  $full = [System.IO.Path]::GetFullPath($Path)
  $drive = $full.Substring(0, 1).ToLowerInvariant()
  $rest = $full.Substring(2).Replace('\', '/')
  return "/$drive$rest"
}

function Resolve-WindowsDirexioHome {
  if ($env:DIREXIO_HOME) {
    $normalized = $env:DIREXIO_HOME.Replace('\', '/')
    if ($normalized -notmatch '^/[A-Za-z](/|$)' -and $normalized -notmatch '^/mnt/[A-Za-z](/|$)' -and $normalized -notmatch '^/cygdrive/[A-Za-z](/|$)') {
      return $env:DIREXIO_HOME
    }
  }
  return Join-Path $env:USERPROFILE '.direxio'
}

function Convert-ArgumentForGitBash([string] $Value) {
  if ($Value -match '^[A-Za-z]:[\\/]') {
    return ConvertTo-GitBashPath $Value
  }
  if ($Value -match '^/mnt/[A-Za-z](/|$)' -or $Value -match '^/cygdrive/[A-Za-z](/|$)') {
    return ConvertTo-GitBashPath $Value
  }
  if ($Value -match '^\.{1,2}[\\/]') {
    return ConvertTo-GitBashPath (Join-Path (Get-Location).ProviderPath $Value)
  }
  return $Value
}
