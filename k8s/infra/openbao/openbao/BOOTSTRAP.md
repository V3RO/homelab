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
kubectl -n openbao exec -it openbao-1 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200
  bao operator raft join http://openbao-0.openbao-internal:8200
'
kubectl -n openbao exec -it openbao-1 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200
  bao operator unseal
'
# repeat for openbao-2, then confirm with:
#   bao operator raft list-peers
```

The listener has `tls_disable = 1`, so `BAO_ADDR`/join targets must use
`http://`, not the CLI's `https://127.0.0.1:8200` default — otherwise you'll
get a TLS handshake error against a plaintext listener. `raft join` must run
*before* unseal: a sealed node can still join and pull a snapshot from the
leader, it just can't decrypt anything until unsealed with the same key
shares used on `openbao-0` (unseal keys are cluster-wide, not per-pod).

Note this is a manual step on **every** pod restart (upgrades, node
drains, crashes) since there's no auto-unseal configured — a deliberate
tradeoff for now, since you're managing init/unseal yourself rather than
via a seal backend wired into this chart.

## 2. Enable secrets engines and auth methods

```bash
# Run inside a pod (e.g. kubectl -n openbao exec -it openbao-0 -- sh), same
# as every other step in this runbook — or https://openbao.schober.dev once
# you've confirmed the HTTPRoute/Gateway path works.
export BAO_ADDR=http://127.0.0.1:8200
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
```

Audit device: **not** a CLI step. Dynamically enabling audit devices via
the API was the vector for CVE-2025-54997 (a root-token holder could point
the audit log at an arbitrary path), so OpenBao now only supports audit
devices declared in the server config — see the `audit "file" ...` stanza
in [helmrelease.yaml](helmrelease.yaml). It's already enabled by the chart;
confirm it loaded with `bao audit list` (needs a rollout restart + re-unseal
of all 3 pods first if you changed it after initial deploy — audit stanzas
are read at boot/SIGHUP, not live).

(Per-database role configuration — e.g. `database/config/authentik-postgres`,
`database/roles/authentik` — is a follow-up task once the CNPG migration
work starts; not required to stand the cluster up.)

## 3. Human access via Authentik OIDC (homelab admins only)

The Authentik side is GitOps-managed — see the `openbao` entry in
[authentik's blueprints.data](../../authentik/authentik/helmrelease.yaml)
(`access: admin`, so only the `homelab-admins` Authentik group can even
reach the consent screen; everyone else is denied before a token is ever
issued). Once that's synced, get the client secret it generated:

```bash
# From wherever you can read Bitwarden Secrets Manager — this is the value
# Authentik generated for the "openbao" OAuth2 provider, item
# authentik-openbao-client-secret in the same project as bitwarden-app-secrets.
```

Then configure OpenBao's side:

```bash
export BAO_ADDR=http://127.0.0.1:8200   # or exec into a pod, as elsewhere
export BAO_TOKEN=<root token>

bao auth enable oidc
bao write auth/oidc/config \
  oidc_discovery_url="https://auth.schober.dev/application/o/openbao/.well-known/openid-configuration" \
  oidc_client_id="openbao" \
  oidc_client_secret="<authentik-openbao-client-secret value>" \
  default_role="homelab-admins"

# Broad-but-not-root policy for logged-in humans. Authentik's access:admin
# binding is the actual gate on who can log in at all — this policy just
# governs what they can do once they're in. Narrow this later if you want
# finer-grained tiers; homelab-admins is currently an all-or-nothing group
# anyway.
cat <<EOF | bao policy write openbao-admins -
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

bao write auth/oidc/role/homelab-admins \
  allowed_redirect_uris="https://openbao.schober.dev/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
  bound_audiences="openbao" \
  user_claim="email" \
  groups_claim="groups" \
  oidc_scopes="openid,profile,email,groups" \
  policies="openbao-admins" \
  ttl="1h" \
  max_ttl="4h"
```

Test from the UI (`https://openbao.schober.dev/ui` → "Sign in with OIDC
Provider") or the CLI:

```bash
bao login -method=oidc role=homelab-admins
```

Note: `/ui/vault/auth/oidc/oidc/callback` has "vault" hardcoded in the path
even on OpenBao — a known naming leftover from the Vault fork, not a typo.

If you later want finer-grained tiers than "all homelab-admins get the same
policy," look at OpenBao's external-groups/identity system
(`identity/group` + `identity/group-alias` keyed off the `groups` claim)
rather than branching within a single role — a role's `policies` field is
a flat list applied to everyone who authenticates through it.

## 4. Wire up the snapshot agent's Kubernetes-auth role

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

## 5. Create the backup bucket

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

## 6. Per-app database credential rotation (vault-config-operator)

One-time per app, once its `DatabaseSecretEngineConfig`/`DatabaseSecretEngineStaticRole`
CRs exist (see e.g. [authentik's openbao-database-config.yaml](../../authentik/authentik/templates/openbao-database-config.yaml)).
`rootCredentials.secret` on `DatabaseSecretEngineConfig` must be
namespace-local to the CR, so each app needs its own scoped
ServiceAccount + Kubernetes-auth role — this can't be folded into the
shared `vault-config-operator` role from step 3.

```bash
cat <<EOF | bao policy write authentik-db-config -
path "database/config/authentik-postgres" {
  capabilities = ["create", "read", "update", "delete"]
}
path "database/static-roles/authentik-static" {
  capabilities = ["create", "read", "update", "delete"]
}
EOF

bao write auth/kubernetes/role/authentik-db-config \
  bound_service_account_names=authentik-openbao \
  bound_service_account_namespaces=authentik \
  policies=authentik-db-config \
  ttl=15m
```

**Also a one-time manual step, specific to `authentik-postgres` being a
pre-existing cluster:** `postInitSQL`/`postInitApplicationSQL` in
`cluster.yaml` only run at initial cluster *creation* — they're a no-op
here (verified against a disposable test cluster before relying on this).
Apply the equivalent grant by hand, once:

```bash
kubectl -n authentik exec -it authentik-postgres-1 -c postgres -- \
  psql -U postgres -d authentik -c \
  'GRANT "authentik" TO "openbao-admin" WITH ADMIN OPTION;'
```

(Any *future* CNPG cluster built from a template that includes these
bootstrap hooks gets this automatically — no manual step needed.)

Once both are done, `DatabaseSecretEngineConfig`/`DatabaseSecretEngineStaticRole`
should reconcile successfully — check with `kubectl -n authentik get
databasesecretengineconfig,databasesecretenginestaticrole`.

**Not done by any of this:** Authentik itself still reads its DB password
from `cnpg-authentik-credentials` (Bitwarden), unaffected. Cutting it over
to the OpenBao-issued credential, and deciding how rotations get picked up
(Reloader vs. long `rotation_period` + manual restart), are separate,
deliberate steps.

## 7. Restore procedure (disaster recovery — test this before you need it)

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
