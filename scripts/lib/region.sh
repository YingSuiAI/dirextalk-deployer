#!/usr/bin/env bash
# lib/region.sh - local AWS region recommendation helpers.

direxio_timezone_name() {
  if [ -n "${TZ:-}" ]; then
    printf '%s\n' "$TZ"
    return 0
  fi
  if [ -f /etc/timezone ]; then
    sed -n '1p' /etc/timezone
    return 0
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl 2>/dev/null |
      sed -nE 's/^[[:space:]]*Time zone:[[:space:]]*([^[:space:]]+).*/\1/p' |
      sed -n '1p'
    return 0
  fi
  return 0
}

direxio_utc_offset_hours() {
  date +%z 2>/dev/null | awk '
    /^[+-][0-9][0-9][0-9][0-9]$/ {
      sign=substr($0,1,1)
      h=substr($0,2,2)+0
      m=substr($0,4,2)+0
      v=h+(m/60)
      if (sign=="-") v=-v
      printf "%.2f\n", v
    }'
}

direxio_recommend_region() {
  local tz offset region reason
  tz=$(direxio_timezone_name)
  offset=$(direxio_utc_offset_hours)
  case "$tz" in
    Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Urumqi|Asia/Hong_Kong|Asia/Macau|Asia/Taipei)
      region=ap-east-1
      reason="timezone $tz maps to Asia Pacific (Hong Kong)"
      ;;
    Asia/Tokyo)
      region=ap-northeast-1
      reason="timezone $tz maps to Asia Pacific (Tokyo)"
      ;;
    Asia/Seoul)
      region=ap-northeast-2
      reason="timezone $tz maps to Asia Pacific (Seoul)"
      ;;
    Asia/Singapore|Asia/Kuala_Lumpur|Asia/Manila)
      region=ap-southeast-1
      reason="timezone $tz maps to Asia Pacific (Singapore)"
      ;;
    Asia/Bangkok|Asia/Jakarta|Asia/Ho_Chi_Minh)
      region=ap-southeast-1
      reason="timezone $tz maps to Asia Pacific (Singapore)"
      ;;
    Australia/*|Pacific/Auckland)
      region=ap-southeast-2
      reason="timezone $tz maps to Asia Pacific (Sydney)"
      ;;
    Europe/*|Africa/*)
      region=eu-central-1
      reason="timezone $tz maps to EU (Frankfurt)"
      ;;
    America/Los_Angeles|America/Vancouver|America/Tijuana)
      region=us-west-2
      reason="timezone $tz maps to US West (Oregon)"
      ;;
    America/New_York|America/Toronto|America/Detroit)
      region=us-east-1
      reason="timezone $tz maps to US East (N. Virginia)"
      ;;
  esac
  if [ -z "$region" ] && [ -n "$offset" ]; then
    if awk -v o="$offset" 'BEGIN{exit !(o >= 7 && o <= 9)}'; then
      region=ap-east-1
      reason="UTC offset $offset maps to Asia Pacific (Hong Kong)"
    elif awk -v o="$offset" 'BEGIN{exit !(o >= -8 && o <= -5)}'; then
      region=us-east-1
      reason="UTC offset $offset maps to US East (N. Virginia)"
    else
      region=us-east-1
      reason="UTC offset $offset has no specific mapping; using US East (N. Virginia)"
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "${region:-us-east-1}" \
    "${tz:-unknown}" \
    "${offset:-unknown}" \
    "${reason:-no timezone data; using US East (N. Virginia)}"
}
