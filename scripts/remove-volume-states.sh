#!/usr/bin/env bash
# Removes the Terraform state entries for all managed Proxmox volumes and
# their corresponding Kubernetes PersistentVolumes.
#
# Usage:
#   ./scripts/remove-volume-states.sh           # dry-run (lists addresses, no removal)
#   ./scripts/remove-volume-states.sh --remove  # actually runs tofu state rm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOFU_DIR="$(cd "${SCRIPT_DIR}/../tofu/kubernetes" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────
DRY_RUN=true
for arg in "$@"; do
  case "$arg" in
    --remove) DRY_RUN=false ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── State addresses to remove ─────────────────────────────────────────────────
STATES=(
  'module.volumes.module.persistent-volume["pv-actual"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-adguard"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-authentik"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-forgejo"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-forgejo-postgres"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-grafana"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-immich-library"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-immich-machine-learning"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-immich-postgres"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-loki"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-mealie-data"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-mealie-postgres"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-mimir-compactor"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-mimir-ingester"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-mimir-store-gateway"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-n8n"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-n8n-postgres"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-prometheus"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-tempo"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-uptime-kuma"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-valkey"].kubernetes_persistent_volume.pv'
  'module.volumes.module.persistent-volume["pv-zot"].kubernetes_persistent_volume.pv'
  'module.volumes.module.proxmox-volume["pv-actual"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-adguard"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-authentik"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-forgejo"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-forgejo-postgres"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-grafana"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-immich-library"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-immich-machine-learning"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-immich-postgres"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-loki"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-mealie-data"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-mealie-postgres"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-mimir-compactor"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-mimir-ingester"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-mimir-store-gateway"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-n8n"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-n8n-postgres"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-prometheus"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-tempo"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-uptime-kuma"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-valkey"].restapi_object.proxmox-volume[0]'
  'module.volumes.module.proxmox-volume["pv-zot"].restapi_object.proxmox-volume[0]'
)

echo "Tofu directory : $TOFU_DIR"
echo "State entries  : ${#STATES[@]}"
echo "Mode           : $([ "$DRY_RUN" = true ] && echo 'dry-run (pass --remove to actually remove)' || echo 'REMOVE')"
echo "────────────────────────────────────────────"

if [[ "$DRY_RUN" = true ]]; then
  echo "Would remove the following state addresses:"
  for state in "${STATES[@]}"; do
    echo "  $state"
  done
  echo ""
  echo "Dry-run complete. Re-run with --remove to remove the state entries above."
  exit 0
fi

# ── Remove all state entries in one call ─────────────────────────────────────
# tofu state rm accepts multiple addresses in a single invocation,
# which is faster and produces a single backup snapshot.
echo "Removing state entries..."
tofu -chdir="$TOFU_DIR" state rm "${STATES[@]}"

echo ""
echo "Done."
