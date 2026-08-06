#!/usr/bin/env bash
# Creates a time-limited OCI Bastion session and keeps a local Dashboard tunnel open.
set -euo pipefail

terraform_dir="terraform"
ssh_private_key="$HOME/.ssh/id_rsa"
local_ssh_port="2222"
local_dashboard_port="9119"
session_ttl="10800"

usage() {
  echo "Usage: $0 [--terraform-dir DIR] [--ssh-private-key PATH] [--local-ssh-port PORT] [--local-dashboard-port PORT] [--session-ttl SECONDS]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) terraform_dir="$2"; shift 2 ;;
    --ssh-private-key) ssh_private_key="$2"; shift 2 ;;
    --local-ssh-port) local_ssh_port="$2"; shift 2 ;;
    --local-dashboard-port) local_dashboard_port="$2"; shift 2 ;;
    --session-ttl) session_ttl="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

for command in terraform oci ssh curl lsof mktemp; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

[[ -f "$ssh_private_key" ]] || { echo "Private key not found: $ssh_private_key" >&2; exit 1; }
[[ -f "${ssh_private_key}.pub" ]] || { echo "Public key not found: ${ssh_private_key}.pub" >&2; exit 1; }

for port in "$local_ssh_port" "$local_dashboard_port"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { echo "Invalid local port: $port" >&2; exit 1; }
  ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null || { echo "Local port $port is already in use. Choose another port, for example: make dashboard LOCAL_DASHBOARD_PORT=9919" >&2; exit 1; }
done

terraform_dir="$(cd "$terraform_dir" && pwd)"
region="$(terraform -chdir="$terraform_dir" output -raw region)"
bastion_id="$(terraform -chdir="$terraform_dir" output -raw bastion_id)"
instance_id="$(terraform -chdir="$terraform_dir" output -raw instance_id)"
private_ip="$(terraform -chdir="$terraform_dir" output -raw private_ip)"
session_file="$terraform_dir/.hermes-bastion-session"
# Use a short, shared local path: macOS's per-user TMPDIR can exceed the
# pathname limit for OpenSSH control sockets and break Bastion authentication.
temporary_directory="$(mktemp -d /private/tmp/hermes-dashboard.XXXXXX)"
control_socket="$temporary_directory/bastion-control"
bastion_known_hosts="$temporary_directory/bastion-known-hosts"
vm_known_hosts="$temporary_directory/vm-known-hosts"
bastion_ssh_log="$temporary_directory/bastion-ssh.log"
dashboard_ssh_log="$temporary_directory/dashboard-ssh.log"
session_id=""
dashboard_ssh_pid=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$dashboard_ssh_pid" ]]; then
    kill "$dashboard_ssh_pid" >/dev/null 2>&1 || true
    wait "$dashboard_ssh_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$session_id" ]]; then
    ssh -S "$control_socket" -O exit -p 22 "$session_id@host.bastion.$region.oci.oraclecloud.com" >/dev/null 2>&1 || true
    oci bastion session delete --region "$region" --session-id "$session_id" --force --wait-for-state SUCCEEDED >/dev/null 2>&1 || true
  fi
  rm -f "$session_file" "$control_socket" "$bastion_known_hosts" "$vm_known_hosts" "$bastion_ssh_log" "$dashboard_ssh_log"
  rmdir "$temporary_directory" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT INT TERM

session_id="$(
  oci bastion session create-port-forwarding \
    --region "$region" \
    --bastion-id "$bastion_id" \
    --target-resource-id "$instance_id" \
    --target-private-ip "$private_ip" \
    --target-port 22 \
    --key-type PUB \
    --ssh-public-key-file "${ssh_private_key}.pub" \
    --session-ttl "$session_ttl" \
    --wait-for-state SUCCEEDED \
    --query 'data.resources[0].identifier' \
    --raw-output
)"

[[ "$session_id" == ocid1.bastionsession.* ]] || { echo "OCI did not return a Bastion session OCID." >&2; exit 1; }
umask 077
printf '%s\n' "$session_id" > "$session_file"

for attempt in {1..30}; do
  session_state="$(oci bastion session get --region "$region" --session-id "$session_id" --query 'data."lifecycle-state"' --raw-output)"
  [[ "$session_state" == "ACTIVE" ]] && break
  [[ "$session_state" != "CREATING" ]] && { echo "Bastion session entered unexpected state: $session_state" >&2; exit 1; }
  sleep 2
done
[[ "${session_state:-}" == "ACTIVE" ]] || { echo "Timed out waiting for the Bastion session to become ACTIVE." >&2; exit 1; }

bastion_connected=false
for attempt in {1..30}; do
  if ssh -i "$ssh_private_key" \
    -o IdentitiesOnly=yes \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$bastion_known_hosts" \
    -o ExitOnForwardFailure=yes \
    -o ControlMaster=yes \
    -o ControlPath="$control_socket" \
    -f -N \
    -L "$local_ssh_port:$private_ip:22" \
    -p 22 \
    "$session_id@host.bastion.$region.oci.oraclecloud.com" 2>"$bastion_ssh_log"; then
    bastion_connected=true
    break
  fi
  sleep 2
done
if [[ "$bastion_connected" != true ]]; then
  cat "$bastion_ssh_log" >&2
  exit 1
fi

ssh -i "$ssh_private_key" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$vm_known_hosts" \
  -o ExitOnForwardFailure=yes \
  -o LogLevel=ERROR \
  -N \
  -L "$local_dashboard_port:127.0.0.1:9119" \
  -p "$local_ssh_port" \
  opc@127.0.0.1 2>"$dashboard_ssh_log" &
dashboard_ssh_pid=$!

echo "Waiting for Hermes Dashboard to become available..."
dashboard_ready=false
for attempt in {1..150}; do
  dashboard_status="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$local_dashboard_port/" || true)"
  if [[ "$dashboard_status" == "200" ]]; then
    dashboard_ready=true
    break
  fi
  if ! kill -0 "$dashboard_ssh_pid" >/dev/null 2>&1; then
    wait "$dashboard_ssh_pid" || true
    cat "$dashboard_ssh_log" >&2
    exit 1
  fi
  sleep 2
done
if [[ "$dashboard_ready" != true ]]; then
  echo "Timed out waiting for Hermes Dashboard on port $local_dashboard_port." >&2
  exit 1
fi

echo "Dashboard ready: http://localhost:$local_dashboard_port"
echo "Press Ctrl-C to close both SSH tunnels and revoke the Bastion session."
wait "$dashboard_ssh_pid"
