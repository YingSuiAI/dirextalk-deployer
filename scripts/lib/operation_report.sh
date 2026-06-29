#!/usr/bin/env bash
# lib/operation_report.sh - redacted operation reports for deploy/destroy flows.

operation_report_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

operation_report_service_id() {
  local state=$1 service_id
  service_id=$(jq -r '.agent_service_id // .domain // empty' "$state")
  printf '%s\n' "${service_id:-unknown-service}"
}

operation_report_default_path() {
  local operation=$1 state=$2 service_id service_dir root
  service_id=$(operation_report_service_id "$state")
  service_dir=$(jq -r '.agent_service_dir // empty' "$state")
  [ -n "$service_dir" ] || service_dir=$(dirname "$state")
  case "$operation" in
    destroy)
      root=${DIREXIO_HOME:-$HOME/.direxio}
      printf '%s/reports/%s/operation-report.json\n' "$root" "$service_id"
      ;;
    *)
      printf '%s/operation-report.json\n' "$service_dir"
      ;;
  esac
}

operation_report_json() {
  local operation=$1 status=$2 state=$3 generated_at=$4
  jq -n \
    --arg operation_type "$operation" \
    --arg status "$status" \
    --arg generated_at "$generated_at" \
    --arg state_json "$state" \
    --slurpfile state "$state" '
      $state[0] as $st |
      def redacted_status:
        if (($st.password // "") | tostring | length) > 0
        then "available_in_state_password_field_redacted"
        else "missing"
        end;
      def phase_statuses:
        ($st.phases // {} | with_entries(.value = (.value.status // "unknown")));
      def user_gate($gate; $default):
        ($st.user_confirmations[$gate].status // $default);
      def local_refresh_status:
        if ($st.agent_install_status // "") == "refresh_pending"
        then "refresh_pending"
        else "current_or_not_recorded"
        end;
      def redact_text($value):
        def redact_one($secret):
          if (($secret // "") | tostring | length) > 0
          then split($secret | tostring) | join("<redacted>")
          else .
          end;
        ($value // "" | tostring)
        | redact_one($st.password)
        | redact_one($st.access_token)
        | redact_one($st.agent_token)
        | redact_one($st.matrix_access_token)
        | redact_one($st.owner_access_token)
        | redact_one($st.aws_secret_access_key)
        | redact_one($st.aws_session_token)
        | gsub("[0-9]{8,}"; "<redacted>");
      def user_gate_detail($gate; $default):
        ($st.user_confirmations[$gate] // {}) as $gate_state |
        {
          status: ($gate_state.status // $default),
          ts: ($gate_state.ts // ""),
          evidence: redact_text($gate_state.evidence // ""),
          evidence_redacted: ((redact_text($gate_state.evidence // "")) != (($gate_state.evidence // "") | tostring))
        }
        + (if $gate == "agent_mcp_runtime" then {
            runtime_summary_status: ($gate_state.runtime_summary_status // ""),
            runtime_probe_confirmed: ($gate_state.runtime_probe_confirmed // false)
          } else {} end);
      def billable:
        [
          (if (($st.resources.instance_id // "") | tostring | length) > 0 then "EC2 \($st.resources.instance_id)" else empty end),
          (if (($st.resources.root_volume_id // "") | tostring | length) > 0 then "EBS root volume \($st.resources.root_volume_id)" else empty end),
          (if (($st.resources.public_ip // "") | tostring | length) > 0 then "public IPv4 \($st.resources.public_ip)" else empty end),
          (if (($st.resources.eip_id // "") | tostring | length) > 0 then "Elastic IP \($st.resources.eip_id)" else empty end),
          (if (($st.resources.route53_zone_id // "") | tostring | length) > 0 then "Route53 hosted zone \($st.resources.route53_zone_id)" else empty end)
        ];
      def destroy_status($key):
        ($st.destroy_evidence[$key].status // "not_checked");
      def status_not_in($status; $safe):
        (($safe | index($status)) == null);
      def destroy_billable_residue:
        [
          (if (($st.resources.instance_id // "") | tostring | length) > 0
              and status_not_in(destroy_status("ec2_instance"); ["terminated", "not_found", "skipped"])
           then "EC2 \($st.resources.instance_id) status=\(destroy_status("ec2_instance"))"
           else empty end),
          (if (($st.resources.root_volume_id // "") | tostring | length) > 0
              and status_not_in(destroy_status("ebs_root_volume"); ["deleted", "skipped"])
           then "EBS root volume \($st.resources.root_volume_id) status=\(destroy_status("ebs_root_volume"))"
           else empty end),
          (if (($st.resources.eip_id // "") | tostring | length) > 0
              and status_not_in(destroy_status("elastic_ip"); ["released", "skipped"])
           then "Elastic IP \($st.resources.eip_id) status=\(destroy_status("elastic_ip"))"
           else empty end),
          (if (($st.resources.route53_zone_id // "") | tostring | length) > 0
              and status_not_in(destroy_status("route53_hosted_zone"); ["deleted", "skipped"])
           then "Route53 hosted zone \($st.resources.route53_zone_id) status=\(destroy_status("route53_hosted_zone"))"
           else empty end)
        ];
      {
        operation_type: $operation_type,
        status: $status,
        generated_at: $generated_at,
        domain: ($st.domain // ""),
        service_id: ($st.agent_service_id // $st.domain // ""),
        service_dir: ($st.agent_service_dir // ""),
        state_json: $state_json,
        delivery: {
          app_domain: ($st.domain // ""),
          product_completion_status: $status,
          init_code_status: redacted_status,
          init_code_secret_redacted: true,
          user_path: "enter app_domain and the eight-digit initialization code in the App"
        },
        agent: {
          node_id: ($st.agent_node_id // ""),
          room_id: ($st.agent_room_id // ""),
          runtime: ($st.agent_runtime // "unknown"),
          service_id: ($st.agent_service_id // $st.domain // ""),
          credentials_file: ($st.agent_credentials_file // "")
        },
        gates: {
          automated: phase_statuses,
          user_confirmation: {
            app_initialization: user_gate("app_initialization"; "pending_user_confirmation"),
            real_chat: user_gate("real_chat"; "pending_user_confirmation"),
            agent_mcp_runtime: user_gate("agent_mcp_runtime"; "pending_runtime_confirmation")
          },
          user_confirmation_details: {
            app_initialization: user_gate_detail("app_initialization"; "pending_user_confirmation"),
            real_chat: user_gate_detail("real_chat"; "pending_user_confirmation"),
            agent_mcp_runtime: user_gate_detail("agent_mcp_runtime"; "pending_runtime_confirmation")
          }
        },
        runtime_checks: {
          summary: ($st.runtime_checks.summary // {status: "not_run"}),
          connect_daemon: ($st.runtime_checks.connect_daemon // {status: "not_run"}),
          mcp_doctor: ($st.runtime_checks.mcp_doctor // {status: "not_run"}),
          mcp_smoke: ($st.runtime_checks.mcp_smoke // {status: "not_run"}),
          mcp_tools: ($st.runtime_checks.mcp_tools // {status: "not_run"})
        },
        credentials: {
          status: local_refresh_status,
          credentials_file: ($st.agent_credentials_file // ""),
          contains_secrets: true,
          values_redacted: true
        },
        connect: {
          package: ($st.cc_connect_npm_package // "@direxio/connent@1.3.10"),
          agent: ($st.cc_connect_agent // ""),
          config: ($st.cc_connect_config // ""),
          install_status: ($st.agent_install_status // "")
        },
        mcp: {
          status: local_refresh_status,
          package: ($st.mcp_npm_package // "@direxio/local-mcp@0.1.6"),
          server_name: ($st.mcp_server_name // ""),
          config_dir: ($st.mcp_config_dir // ""),
          codex: ($st.mcp_codex_config // ""),
          openclaw: ($st.mcp_openclaw_config // ""),
          hermes: ($st.mcp_hermes_config // ""),
          doctor: ($st.mcp_doctor_command // "")
        },
        resources: {
          region: ($st.region // ""),
          domain_mode: ($st.domain_mode // ""),
          instance_type: ($st.instance_type // ""),
          instance_id: ($st.resources.instance_id // ""),
          root_volume_id: ($st.resources.root_volume_id // ""),
          public_ip: ($st.resources.public_ip // ""),
          eip_id: ($st.resources.eip_id // ""),
          route53_zone_id: ($st.resources.route53_zone_id // ""),
          route53_zone_name: ($st.resources.route53_zone_name // ""),
          route53_zone_created_by_deployer: ($st.resources.route53_zone_created_by_deployer // ""),
          route53_name_servers: ($st.resources.route53_name_servers // ""),
          route53_existing_a_value: ($st.resources.route53_existing_a_value // ""),
          route53_pending_a_value: ($st.resources.route53_pending_a_value // ""),
          route53_overwrite_confirmed: ($st.resources.route53_overwrite_confirmed // ""),
          sg_id: ($st.resources.sg_id // ""),
          key_name: ($st.resources.key_name // "")
        },
        billing: {
          keeps_billing_until_destroy: ($operation_type != "destroy"),
          recorded_billable_resources: billable,
          cost_estimate: ($st.cost_estimate // null),
          destroy_cleanup_status: (
            if $operation_type != "destroy" then "not_destroy"
            elif (destroy_billable_residue | length) == 0 then "no_recorded_billable_resource_residue"
            else "possible_billable_resource_residue"
            end
          ),
          possible_remaining_billable_resources: (
            if $operation_type == "destroy" then destroy_billable_residue else [] end
          )
        },
        security: {
          secrets_included: false,
          values_redacted: true,
          root_access_key_allowed: false,
          temporary_iam_cleanup_required: true,
          temporary_iam_cleanup_action: "delete or disable the temporary DirexioDeployer access key after deployment, or reduce it to a maintenance-only policy"
        }
      }
      + (if $operation_type == "destroy" then {
          destroy: {
            resources_processed_from_state: true,
            user_managed_dns_not_removed: true,
            purchased_domain_not_removed: true,
            local_service_dir: ($st.agent_service_dir // ""),
            evidence: ($st.destroy_evidence // {})
          }
        } else {} end)
    '
}

operation_report_write() {
  local operation=$1 status=$2 state=$3 output=${4:-} generated_at tmp
  [ -f "$state" ] || {
    echo "state.json not found for operation report: $state" >&2
    return 1
  }
  [ -n "$output" ] || output=$(operation_report_default_path "$operation" "$state")
  mkdir -p "$(dirname "$output")"
  generated_at=$(operation_report_now)
  tmp="$output.tmp.$$"
  operation_report_json "$operation" "$status" "$state" "$generated_at" > "$tmp"
  mv "$tmp" "$output"
  printf '%s\n' "$output"
}
