#!/usr/bin/env bash
# Removes all disks on the Proxmox instance that are prefixed with vm-9999
# from the local-lvm storage.
#
# Usage:
#   ./scripts/remove-vm-9999-disks.sh           # dry-run (lists disks, no deletion)
#   ./scripts/remove-vm-9999-disks.sh --delete  # actually deletes matching disks
#
# Credentials are read from tofu/kubernetes/proxmox.auto.tfvars (relative to repo root).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${REPO_ROOT}/tofu/kubernetes/proxmox.auto.tfvars"
STORAGE="local-lvm"
PREFIX="vm-9999"

# ── Parse arguments ───────────────────────────────────────────────────────────
DRY_RUN=true
for arg in "$@"; do
  case "$arg" in
    --delete) DRY_RUN=false ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Read Proxmox credentials from tfvars ──────────────────────────────────────
if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: tfvars file not found: $TFVARS" >&2
  exit 1
fi

# Extract the full API token value: root@pam!terraform=<uuid>
# The Authorization header is: PVEAPIToken=root@pam!terraform=<uuid>
PROXMOX_API_TOKEN="$(grep 'proxmox_api_token' "$TFVARS" | sed 's/.*= *"\(.*\)"/\1/')"

# Extract endpoint (https, as Proxmox requires TLS; --insecure skips cert validation)
PROXMOX_ENDPOINT="$(grep 'endpoint' "$TFVARS" | sed 's/.*= *"\(.*\)"/\1/')"

# The Proxmox node name is the PVE hostname, not the cluster name.
# All volumes in this repo are provisioned on node "atheon".
PROXMOX_NODE="atheon"

if [[ -z "$PROXMOX_API_TOKEN" || -z "$PROXMOX_ENDPOINT" ]]; then
  echo "ERROR: Could not parse required fields from $TFVARS" >&2
  exit 1
fi

AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_API_TOKEN}"
BASE_URL="${PROXMOX_ENDPOINT}/api2/json"

echo "Proxmox endpoint : $PROXMOX_ENDPOINT"
echo "Node             : $PROXMOX_NODE"
echo "Storage          : $STORAGE"
echo "Prefix filter    : $PREFIX"
echo "Mode             : $([ "$DRY_RUN" = true ] && echo 'dry-run (pass --delete to actually remove)' || echo 'DELETE')"
echo "────────────────────────────────────────────"

# ── List all volumes in storage ───────────────────────────────────────────────
CONTENT_URL="${BASE_URL}/nodes/${PROXMOX_NODE}/storage/${STORAGE}/content"

response="$(curl -fsSL --insecure \
  -H "$AUTH_HEADER" \
  "$CONTENT_URL")"

# Extract volids where the disk name starts with the prefix
VOLIDS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && VOLIDS+=("$line")
done < <(
  printf '%s' "$response" \
  | grep -oE '"volid":"[^"]*vm-9999[^"]*"' \
  | sed 's/"volid":"//;s/"//'
)

if [[ ${#VOLIDS[@]} -eq 0 ]]; then
  echo "No disks found matching prefix '${PREFIX}' in storage '${STORAGE}'."
  exit 0
fi

echo "Found ${#VOLIDS[@]} disk(s) matching '${PREFIX}':"
for volid in "${VOLIDS[@]}"; do
  echo "  $volid"
done
echo ""

if [[ "$DRY_RUN" = true ]]; then
  echo "Dry-run complete. Re-run with --delete to remove the disks above."
  exit 0
fi

# ── Delete matching volumes ───────────────────────────────────────────────────
echo "Deleting disks..."
ERRORS=0
for volid in "${VOLIDS[@]}"; do
  # volid format: local-lvm:vm-9999-<name>  →  URL-encode the colon as %3A
  encoded_volid="${volid//:/%3A}"
  DELETE_URL="${BASE_URL}/nodes/${PROXMOX_NODE}/storage/${STORAGE}/content/${encoded_volid}"

  echo -n "  Deleting $volid ... "
  if curl -fsSL --insecure \
    -X DELETE \
    -H "$AUTH_HEADER" \
    "$DELETE_URL" > /dev/null; then
    echo "OK"
  else
    echo "FAILED"
    ERRORS=$(( ERRORS + 1 ))
  fi
done

echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  echo "Done with $ERRORS error(s)." >&2
  exit 1
else
  echo "Done. All matching disks removed."
fi
