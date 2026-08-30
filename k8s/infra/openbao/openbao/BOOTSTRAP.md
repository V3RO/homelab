# OpenBao bootstrap runbook

One-time, manual steps. These are deliberately **not** GitOps-managed —
initializing/unsealing a secret store and creating its own backup bucket
can't depend on the secret store already working. Run these once after
Flux has reconciled the `openbao` HelmRelease and the 3 pods are up
(sealed, uninitialized).

## 1. Initialize and unseal

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator init
```

This uses the default Shamir seal (no seal stanza is configured in
[helmrelease.yaml](helmrelease.yaml)) and produces a set of unseal key
shares plus a root token. **Storing these is on you** — wherever you keep
them, treat them as the highest-value secret in the cluster; losing them
means losing everything OpenBao holds.

Unseal `openbao-0` with a quorum of the key shares:

```bash
kubectl -n openbao exec -it openbao-0 -- bao operator unseal
# repeat with each key share until the threshold is met
```

Then join and unseal the other two pods:

```bash
kubectl -n openbao exec -it openbao-1 -- bao operator raft join \
  https://openbao-0.openbao-internal:8200
kubectl -n openbao exec -it openbao-1 -- bao operator unseal
# repeat for openbao-2
```

Note this is a manual step on **every** pod restart (upgrades, node
drains, crashes) since there's no auto-unseal configured — a deliberate
tradeoff for now, since you're managing init/unseal yourself rather than
via a seal backend wired into this chart.

## 2. Enable secrets engines and auth methods

```bash
export BAO_ADDR=https://openbao.schober.dev
export BAO_TOKEN=<root token from step 1>

# KV v2 — static secrets (e.g. OIDC client secrets, replacing Bitwarden for these)
bao secrets enable -path=kv kv-v2

# Database secrets engine — dynamic Postgres roles against the CNPG clusters
bao secrets enable database

# Database secrets engine — dynamic Valkey ACL users
# (same "database" mount, configured per-target with the redis plugin)

# Kubernetes auth — lets in-cluster workloads authenticate with their own
# ServiceAccount token instead of a static OpenBao token
bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# Audit device — tamper-evident log of every secret access
bao audit enable file file_path=/openbao/audit/audit.log
```

(Per-database role configuration — e.g. `database/config/authentik-postgres`,
`database/roles/authentik` — is a follow-up task once the CNPG migration
work starts; not required to stand the cluster up.)

## 3. Wire up the snapshot agent's Kubernetes-auth role

The `openbao-snapshot` CronJob (see [helmrelease.yaml](helmrelease.yaml))
authenticates via Kubernetes auth to read `sys/storage/raft/snapshot`. It
does **not** use the root token.

```bash
cat <<EOF | bao policy write openbao-snapshot -
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

bao write auth/kubernetes/role/openbao-snapshot \
  bound_service_account_names=openbao-snapshot \
  bound_service_account_namespaces=openbao \
  policies=openbao-snapshot \
  ttl=15m
```

## 4. Create the backup bucket

The snapshot CronJob uploads to `s3://openbao-backups/` on VersityGW, using
the reused VersityGW root credential (see
[external-secret.yaml](templates/external-secret.yaml) for the tradeoff
rationale — this is deliberately *not* minted by OpenBao's own dynamic
secrets, so restore never depends on OpenBao being alive).

```bash
mc alias set versitygw http://versitygw.versitygw.svc.cluster.local:7070 \
  <versitygw-access-key-id> <versitygw-secret-access-key>
mc mb versitygw/openbao-backups
```

Verify the first snapshot lands after the next `0 3 * * *` run, or trigger
one manually: `kubectl -n openbao create job --from=cronjob/openbao-snapshot
openbao-snapshot-manual`.

## 5. Restore procedure (disaster recovery — test this before you need it)

1. Deploy a fresh `openbao` release and run `bao operator init` + unseal on
   it (step 1) — this cluster will have its **own**, newly generated unseal
   keys/root token, independent of the source cluster's.
2. Fetch the latest snapshot from `s3://openbao-backups/` using the same
   static VersityGW credential from step 4 (`mc cp
   versitygw/openbao-backups/<latest>.snap ./restore.snap`).
3. `bao operator raft snapshot restore -force ./restore.snap` — `-force` is
   required since this pod's own (fresh) init state doesn't match the
   snapshot's origin cluster; per OpenBao/Vault docs this is expected.
4. Per Vault/OpenBao's documented behavior, unsealing **after** this restore
   requires the **original source cluster's** unseal keys, not the fresh
   ones generated in step 1 — the restore replaces the barrier keyring
   with the source's. Keep the source cluster's unseal keys available
   specifically for this scenario, separate from day-to-day operation.
5. Scale back to 3 replicas; nodes 2/3 rejoin raft and replicate from the
   restored leader.
6. Re-run `bao status`, `bao secrets list`, `bao auth list` to confirm
   engines/policies came back, then confirm ESO's OpenBao-backed
   ExternalSecrets (once that migration exists) resync cleanly.
