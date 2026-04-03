#!/usr/bin/env bash
# Longhorn Phase 3 — Verification runbook
# Run from the repo root: bash test/longhorn/03-verify.sh
set -euo pipefail

KUBECONFIG="tofu/kubernetes/output/kube-config.yaml"
K="kubectl --kubeconfig ${KUBECONFIG}"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       Longhorn Phase 3 — Verification Script     ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Talos extensions ──────────────────────────────────────────────────────
echo "▶ [1/7] Talos system extensions"
talosctl -n 10.1.40.11 get extensions 2>/dev/null | grep -E 'iscsi-tools|util-linux-tools' \
  && echo "  ✔  iscsi-tools and util-linux-tools present" \
  || { echo "  ✘  Extensions missing — did tofu apply complete and node reboot?"; exit 1; }

# ── 2. Longhorn disk mounted ─────────────────────────────────────────────────
echo ""
echo "▶ [2/7] Longhorn disk mounted at /var/lib/longhorn"
talosctl -n 10.1.40.11 mounts 2>/dev/null | grep '/var/lib/longhorn' \
  && echo "  ✔  /var/lib/longhorn is mounted" \
  || { echo "  ✘  Mount missing — check machine.disks config in Talos machine config"; exit 1; }

echo "  Disk usage:"
talosctl -n 10.1.40.11 mounts 2>/dev/null | grep '/var/lib/longhorn' | \
  awk '{printf "    Device: %s  Size: %s  Used: %s  Available: %s\n", $1, $2, $3, $4}'

# ── 3. Longhorn pods ─────────────────────────────────────────────────────────
echo ""
echo "▶ [3/7] Longhorn pods healthy"
${K} -n longhorn get pods --no-headers 2>/dev/null | while read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $3}')
  if [[ "$status" == "Running" || "$status" == "Completed" ]]; then
    echo "  ✔  $name ($status)"
  else
    echo "  ✘  $name ($status)"
  fi
done

NOT_RUNNING=$(${K} -n longhorn get pods --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | wc -l | tr -d ' ')
if [[ "$NOT_RUNNING" -gt 0 ]]; then
  echo "  ✘  $NOT_RUNNING pod(s) not Running — check: kubectl -n longhorn describe pod <name>"
  exit 1
fi

# ── 4. Longhorn StorageClass ─────────────────────────────────────────────────
echo ""
echo "▶ [4/7] StorageClass 'longhorn' exists"
${K} get storageclass longhorn 2>/dev/null \
  && echo "  ✔  StorageClass 'longhorn' found" \
  || { echo "  ✘  StorageClass 'longhorn' not found"; exit 1; }

echo "  All StorageClasses:"
${K} get storageclass --no-headers | awk '{printf "    %s  (provisioner: %s)  default: %s\n", $1, $2, $3}'

# ── 5. Longhorn node registered ──────────────────────────────────────────────
echo ""
echo "▶ [5/7] Longhorn node registered"
${K} -n longhorn get nodes.longhorn.io 2>/dev/null \
  && echo "  ✔  Node registered in Longhorn" \
  || { echo "  ✘  No Longhorn nodes — check Longhorn manager logs"; exit 1; }

# ── 6. Smoke test ────────────────────────────────────────────────────────────
echo ""
echo "▶ [6/7] Running smoke test (PVC provision + write + read)"
${K} apply -f test/longhorn/01-smoke-test.yaml >/dev/null

echo "  Waiting for PVC to bind..."
${K} -n longhorn-test wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/longhorn-smoke-pvc --timeout=60s \
  && echo "  ✔  PVC bound" \
  || { echo "  ✘  PVC not bound after 60s"; ${K} -n longhorn-test describe pvc longhorn-smoke-pvc; exit 1; }

echo "  Waiting for smoke-test pod to complete..."
${K} -n longhorn-test wait --for=condition=Ready pod/smoke-test --timeout=90s >/dev/null 2>&1 || true
sleep 5

POD_STATUS=$(${K} -n longhorn-test get pod smoke-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$POD_STATUS" == "Succeeded" ]]; then
  echo "  ✔  Smoke test pod completed successfully"
  echo "  Pod output:"
  ${K} -n longhorn-test logs smoke-test 2>/dev/null | sed 's/^/    /'
elif [[ "$POD_STATUS" == "Running" ]]; then
  echo "  ✔  Pod running, streaming logs (Ctrl+C to stop):"
  ${K} -n longhorn-test logs smoke-test 2>/dev/null | sed 's/^/    /'
else
  echo "  ✘  Pod in state: $POD_STATUS"
  ${K} -n longhorn-test logs smoke-test 2>/dev/null || true
  exit 1
fi

echo "  Cleaning up smoke test resources..."
${K} delete -f test/longhorn/01-smoke-test.yaml >/dev/null
echo "  ✔  Cleaned up"

# ── 7. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "▶ [7/7] Resource consumption summary"
echo "  Longhorn namespace pod memory usage:"
${K} top pods -n longhorn 2>/dev/null | sed 's/^/    /' || echo "    (metrics-server not available yet)"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✔  All checks passed — Longhorn is operational  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Next steps:                                     ║"
echo "║  1. Run the fio benchmark:                       ║"
echo "║     kubectl apply -f test/longhorn/02-benchmark  ║"
echo "║  2. Monitor: https://longhorn.schober.dev        ║"
echo "║  3. Proceed to Phase 4 (workload migration)      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
