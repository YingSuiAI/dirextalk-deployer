#!/usr/bin/env bash
# Cross-platform private file/directory permissions. Windows ACLs are applied
# before secret data is written so inherited broad access never sees content.

_dirextalk_windows_private_acl() {
  local path=$1 kind=$2 win_path script
  command -v powershell.exe >/dev/null 2>&1 || return 1
  win_path=$path
  if command -v cygpath >/dev/null 2>&1; then
    win_path=$(cygpath -w "$path") || return 1
  fi
  script='$ErrorActionPreference="Stop"; $path=$env:DIREXTALK_PRIVATE_PATH; $kind=$env:DIREXTALK_PRIVATE_KIND; $acl=New-Object System.Security.AccessControl.DirectorySecurity; if($kind -eq "file"){$acl=New-Object System.Security.AccessControl.FileSecurity}; $acl.SetAccessRuleProtection($true,$false); $ids=@([System.Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")),(New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544"))); foreach($id in $ids){ if($kind -eq "dir"){$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($id,"FullControl","ContainerInherit,ObjectInherit","None","Allow")}else{$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($id,"FullControl","Allow")}; [void]$acl.AddAccessRule($rule) }; if($kind -eq "file"){[System.IO.File]::SetAccessControl($path,$acl); $actual=[System.IO.File]::GetAccessControl($path)}else{[System.IO.Directory]::SetAccessControl($path,$acl); $actual=[System.IO.Directory]::GetAccessControl($path)}; if(-not $actual.AreAccessRulesProtected){exit 2}; $allowed=@($actual.Access | Where-Object {$_.AccessControlType -eq "Allow"}); if($allowed.Count -lt 3){exit 3}'
  DIREXTALK_PRIVATE_PATH="$win_path" DIREXTALK_PRIVATE_KIND="$kind" MSYS2_ARG_CONV_EXCL='*' \
    powershell.exe -NoProfile -NonInteractive -Command "$script" >/dev/null 2>&1
}

dirextalk_restrict_private_file() {
  local file=$1 uname_s
  chmod 600 "$file" || return 1
  uname_s=$(uname -s 2>/dev/null || printf unknown)
  case "$uname_s" in
    MINGW*|MSYS*|CYGWIN*) _dirextalk_windows_private_acl "$file" file || return 1 ;;
  esac
}

dirextalk_restrict_private_directory() {
  local directory=$1 uname_s
  chmod 700 "$directory" || return 1
  uname_s=$(uname -s 2>/dev/null || printf unknown)
  case "$uname_s" in
    MINGW*|MSYS*|CYGWIN*) _dirextalk_windows_private_acl "$directory" dir || return 1 ;;
  esac
}
