#!/usr/bin/env bash
# lib/domain.sh - domain/DNS helpers for the production deployment path.

domain_normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

domain_is_formal_name() {
  local domain=$1 label
  domain=$(domain_normalize "$domain")
  [ -n "$domain" ] || return 1
  [ "${#domain}" -le 253 ] || return 1
  [[ "$domain" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && return 1
  case "$domain" in
    "."*|*"."|*..*|*"_"*|*"/"*|*":"*|*"*"*|localhost|*.localhost|*sslip.io|*.sslip.io|*nip.io|*.nip.io|*xip.io|*.xip.io|*localtest.me|*.localtest.me|*lvh.me|*.lvh.me)
      return 1
      ;;
    *.*) ;;
    *) return 1 ;;
  esac
  IFS=. read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [ -n "$label" ] || return 1
    [ "${#label}" -le 63 ] || return 1
    case "$label" in
      -*|*-|*[!A-Za-z0-9-]*)
        return 1
        ;;
    esac
  done
  return 0
}

# Print the longest matching public Route53 hosted zone as "id<TAB>name".
# Return 1 when the current AWS account has no matching zone and 2 when AWS
# could not be queried, so callers never confuse missing IAM permission with
# externally managed DNS.
route53_find_public_hosted_zone() {
  local domain=$1 best_id="" best_name="" best_len=0 id name private clean len zones_json
  zones_json=$(aws route53 list-hosted-zones --output json) || return 2
  while IFS=$'\t' read -r id name private; do
    id=${id%$'\r'}
    name=${name%$'\r'}
    private=${private%$'\r'}
    [ "$private" = "true" ] && continue
    clean=${name%.}
    case "$domain" in
      "$clean"|*."$clean")
        len=${#clean}
        if [ "$len" -gt "$best_len" ]; then
          best_id=${id#/hostedzone/}
          best_name=$clean
          best_len=$len
        fi
        ;;
    esac
  done < <(printf '%s\n' "$zones_json" | json_stdin_tsv HostedZones Id Name Config.PrivateZone)
  [ -n "$best_id" ] || return 1
  printf '%s\t%s\n' "$best_id" "$best_name"
}

domain_has_dns_record() {
  local domain=$1
  [ -n "$domain" ] || return 1

  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" 2>/dev/null | grep -qE '^[0-9.]+$' && return 0
    dig +short AAAA "$domain" 2>/dev/null | grep -q ':' && return 0
    dig +short CNAME "$domain" 2>/dev/null | grep -q '.' && return 0
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$domain" 2>/dev/null | grep -qE 'Address: [0-9a-fA-F:.]+' && return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Resolve-DnsName -Name '$domain' -Type A -ErrorAction SilentlyContinue | Where-Object { \$_.IPAddress } | Select-Object -First 1" >/dev/null 2>&1 && return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    getent hosts "$domain" 2>/dev/null | grep -qE '^[0-9a-fA-F:.]+' && return 0
  fi

  return 1
}

domain_authoritative_servers() {
  local domain=$1 query labels i zone servers
  [ -n "$domain" ] || return 1

  if command -v powershell.exe >/dev/null 2>&1; then
    query=$(printf '%s' "$domain" | sed "s/'/''/g")
    powershell.exe -NoProfile -Command "
      \$labels = '$query'.Split('.');
      for (\$i = 0; \$i -lt \$labels.Length - 1; \$i++) {
        \$zone = (\$labels[\$i..\$(\$labels.Length - 1)] -join '.');
        \$servers = Resolve-DnsName -Name \$zone -Type NS -ErrorAction SilentlyContinue |
          Where-Object { \$_.NameHost } |
          Select-Object -ExpandProperty NameHost;
        if (\$servers) {
          \$servers | ForEach-Object { \$_.TrimEnd('.') };
          exit 0;
        }
      }
      exit 1
    " 2>/dev/null && return 0
  fi

  if command -v dig >/dev/null 2>&1; then
    IFS=. read -r -a labels <<< "$domain"
    for ((i=0; i<${#labels[@]}-1; i++)); do
      zone=$(IFS=.; echo "${labels[*]:$i}")
      servers=$(dig +short NS "$zone" 2>/dev/null | sed 's/\.$//' | sed '/^$/d')
      [ -n "$servers" ] && { printf '%s\n' "$servers"; return 0; }
    done
  fi

  if command -v nslookup >/dev/null 2>&1; then
    IFS=. read -r -a labels <<< "$domain"
    for ((i=0; i<${#labels[@]}-1; i++)); do
      zone=$(IFS=.; echo "${labels[*]:$i}")
      servers=$(nslookup -type=NS "$zone" 2>/dev/null | awk '/nameserver =/ { sub(/\.$/, "", $4); print $4 }')
      [ -n "$servers" ] && { printf '%s\n' "$servers"; return 0; }
    done
  fi

  return 1
}

domain_authoritative_resolves_to_ip() {
  local domain=$1 ip=$2 server found=0
  [ -n "$domain" ] && [ -n "$ip" ] || return 2

  while IFS= read -r server; do
    server=${server%$'\r'}
    server=${server%.}
    [ -n "$server" ] || continue
    found=1

    if command -v dig >/dev/null 2>&1; then
      dig +short "@$server" A "$domain" 2>/dev/null | grep -qFx "$ip" && return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
      nslookup "$domain" "$server" 2>/dev/null | awk -v want="$ip" '
        /^Name:/ { in_answer = 1; next }
        in_answer && /^Address:[[:space:]]*/ {
          addr = $2
          sub(/#.*$/, "", addr)
          if (addr == want) found = 1
        }
        END { exit(found ? 0 : 1) }
      ' && return 0
    fi

    if command -v powershell.exe >/dev/null 2>&1; then
      powershell.exe -NoProfile -Command "\$r = Resolve-DnsName -Name '$domain' -Type A -Server '$server' -ErrorAction SilentlyContinue | Where-Object { \$_.IPAddress -eq '$ip' }; if (\$r) { exit 0 } else { exit 1 }" >/dev/null 2>&1 && return 0
    fi
  done < <(domain_authoritative_servers "$domain")

  [ "$found" -eq 1 ] && return 1
  return 2
}

domain_resolves_to_ip() {
  local domain=$1 ip=$2 auth_rc
  [ -n "$domain" ] && [ -n "$ip" ] || return 1

  domain_authoritative_resolves_to_ip "$domain" "$ip"
  auth_rc=$?
  case "$auth_rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac

  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" 2>/dev/null | grep -qFx "$ip" && return 0
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$domain" 2>/dev/null | awk -v want="$ip" '
      /^Name:/ { in_answer = 1; next }
      in_answer && /^Address:[[:space:]]*/ {
        addr = $2
        sub(/#.*$/, "", addr)
        if (addr == want) found = 1
      }
      END { exit(found ? 0 : 1) }
    ' && return 0
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "\$r = Resolve-DnsName -Name '$domain' -Type A -ErrorAction SilentlyContinue | Where-Object { \$_.IPAddress -eq '$ip' }; if (\$r) { exit 0 } else { exit 1 }" >/dev/null 2>&1 && return 0
    local server
    while IFS= read -r server; do
      server=${server%$'\r'}
      [ -n "$server" ] || continue
      powershell.exe -NoProfile -Command "\$r = Resolve-DnsName -Name '$domain' -Type A -Server '$server' -ErrorAction SilentlyContinue | Where-Object { \$_.IPAddress -eq '$ip' }; if (\$r) { exit 0 } else { exit 1 }" >/dev/null 2>&1 && return 0
    done < <(domain_authoritative_servers "$domain")
  fi

  return 1
}
