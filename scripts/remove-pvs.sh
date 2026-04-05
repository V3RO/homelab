#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-tofu/kubernetes/output/kube-config.yaml}"

echo "Removing finalizers from all PVs and deleting them..."

for pv in $(kubectl --kubeconfig "$KUBECONFIG" get pv -o jsonpath='{.items[*].metadata.name}'); do
  echo "Deleting PV: $pv"
  kubectl --kubeconfig "$KUBECONFIG" delete pv "$pv" --wait=false

  echo "Patching finalizers on PV: $pv"
  kubectl --kubeconfig "$KUBECONFIG" patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge
done

echo "Done."
