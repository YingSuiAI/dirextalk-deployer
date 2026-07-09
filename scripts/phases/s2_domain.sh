#!/usr/bin/env bash
# S2 DOMAIN_DECISION — validate the production Matrix server_name.
#
# Dirextalk production deployments require a real, long-lived domain. Temporary
# sslip.io/public-IP domains are intentionally not part of this interface.
#
# Supported modes:
#   DOMAIN_MODE=user    user owns DNS; S3 waits until A record points at the EIP
#   DOMAIN_MODE=route53 Route53 hosted zone; ops manages the A record
#
# If DOMAIN_MODE is omitted but DOMAIN is present, user mode is assumed.
# DIREXTALK_ASSUME_DEFAULTS never chooses a domain.

S2_PHASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
source "$S2_PHASE_DIR/lib/domain.sh"

_print_domain_onboarding_guide() {
  warn "First question: do you already own a long-lived domain or subdomain and can edit its DNS records?"
  warn "  If not, register a domain with Route53, Cloudflare, Alibaba Cloud, GoDaddy, or another registrar, then choose a subdomain such as chat.your-domain.tld."
  warn "  If AWS Route53 will manage DNS, use DOMAIN_MODE=route53 and delegate the registrar nameservers to Route53 when asked."
  warn "  If another DNS provider manages the domain, use DOMAIN_MODE=user; the deployer will print the fixed public IP and wait for you to create an A record."
  warn "  The Matrix server_name is bound to DOMAIN. Changing it later is effectively a new homeserver, so choose the final domain before provisioning."
}

run_phase() {
  phase_set S2_DOMAIN in_progress "validating production domain"

  local mode=${DOMAIN_MODE:-}
  local domain=${DOMAIN:-}

  if [ -z "$mode" ]; then
    if [ -n "$domain" ]; then
      mode=user
    elif [ -t 0 ]; then
      warn "Dirextalk requires a production domain as the Matrix server_name."
      warn "Changing the domain is effectively a new homeserver identity; temporary sslip.io defaults are not supported."
      printf "Enter the final domain (for example __DOMAIN__): " >&2
      read -r domain
      [ -n "$domain" ] || {
        phase_set S2_DOMAIN waiting_user "waiting for production domain"
        warn "DOMAIN was not provided. Prepare a production domain and DNS control first."
        _print_domain_onboarding_guide
        return 2
      }
      mode=user
    else
      phase_set S2_DOMAIN waiting_user "waiting for production domain"
      warn "Deployment blocked: DOMAIN is missing. Dirextalk no longer supports temporary sslip.io defaults."
      warn "Prepare a production domain such as __DOMAIN__. Matrix server_name binds to that domain; changing it later is effectively a new homeserver identity."
      _print_domain_onboarding_guide
      warn "Example:"
      warn "  DOMAIN=__DOMAIN__ DOMAIN_MODE=user CONFIRM_DOMAIN_BINDING=1 bash scripts/orchestrate.sh"
      return 2
    fi
  fi

  if [ -z "$domain" ]; then
    phase_set S2_DOMAIN waiting_user "$mode mode requires DOMAIN"
    warn "Deployment blocked: DOMAIN_MODE=$mode requires explicit DOMAIN."
    warn "Example: DOMAIN=__DOMAIN__ DOMAIN_MODE=$mode CONFIRM_DOMAIN_BINDING=1 bash scripts/orchestrate.sh"
    return 2
  fi
  domain=$(domain_normalize "$domain")
  if ! domain_is_formal_name "$domain"; then
    phase_set S2_DOMAIN waiting_user "DOMAIN is not a valid production domain"
    warn "Deployment blocked: DOMAIN=$domain is not a valid production domain."
    warn "Use a long-lived domain you own and can manage in DNS, such as __DOMAIN__. IPs, localhost, wildcards, and temporary resolver domains are not accepted."
    _print_domain_onboarding_guide
    return 2
  fi

  if [ "${CONFIRM_DOMAIN_BINDING:-0}" != "1" ]; then
    phase_set S2_DOMAIN waiting_user "domain binding irreversibility not confirmed"
    warn "Deployment blocked: Matrix server_name domain binding must be confirmed."
    warn "After $domain becomes server_name, changing the domain is effectively a new homeserver identity."
    warn "Rerun after confirmation:"
    warn "  DOMAIN=$domain DOMAIN_MODE=$mode CONFIRM_DOMAIN_BINDING=1 bash scripts/orchestrate.sh"
    return 2
  fi

  case "$mode" in
    user)
      state_set domain_mode user
      state_set domain "$domain"
      state_set_raw domain_confirmed_irreversible 'true'
      warn "Domain mode = user ($domain). S3 will wait for the DNS A record to point at the new EIP."
      warn "If DNS is hosted on Cloudflare, set the record to DNS only; do not enable proxying."
      ;;
    route53)
      state_set domain_mode route53
      state_set domain "$domain"
      state_set_raw domain_confirmed_irreversible 'true'
      log "Domain mode = route53 ($domain). The agent will create the A record automatically; IAM needs Route53 permissions."
      ;;
    buy)
      phase_set S2_DOMAIN waiting_user "automatic domain purchase disabled"
      warn "buy mode is disabled: ops will not purchase domains automatically."
      warn "Domain purchase involves billing, identity/compliance steps, and irreversible ownership decisions."
      warn "Prepare the domain manually, then use DOMAIN=$domain with DOMAIN_MODE=user or DOMAIN_MODE=route53."
      return 2
      ;;
    *)
      phase_set S2_DOMAIN failed "unknown DOMAIN_MODE=$mode"
      fail "Unknown DOMAIN_MODE=$mode (expected user|route53; ec2 temporary-domain mode was removed, buy mode is disabled)." ;;
  esac

  if [ "${DOMAIN_VERIFIED:-0}" != "1" ] && ! domain_has_dns_record "$domain"; then
    warn "No A/AAAA/CNAME record was found for $domain."
    warn "If this is a new domain, confirm DNS hosting is active. S3 will still wait for the A record to point at the new EIP."
  fi

  phase_set S2_DOMAIN done "mode=$mode domain=$domain"
  return 0
}
