# Talos bare-metal cluster

Plain `talosctl` config/patches + a `Makefile` for bringing up the
3-node all-control-plane Talos cluster directly on bare metal (no
OpenTofu, no Proxmox). Nodes:

| Node    | Physical host | IP           | Install disk    |
|---------|---------------|--------------|------------------|
| ctrl-01 | atheon        | 10.1.40.10   | `/dev/nvme0n1`   |
| ctrl-02 | panoptes      | 10.1.40.11   | `/dev/nvme0n1`   |
| ctrl-03 | quria         | 10.1.40.12   | `/dev/nvme0n1`   |

**Networking assumption:** each node's switch port must be configured as
an **access port, native VLAN 40** (untagged) — matching how Proxmox
tagged VLAN 40 at the bridge before. `patches/nodes/ctrl-0X.yaml` sets the
IP directly on the physical interface (`eno2`) with no VLAN tagging, which
only works if the switch hands it untagged VLAN 40 traffic. If a NIC ever
needs to carry more than one VLAN, use Talos's `VLANConfig` document
(https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/vlanconfig)
instead — but note maintenance-mode DHCP (before any config is applied)
only works on the port's native/untagged VLAN, so the trunk's native VLAN
would still need to be 40 for the initial `apply-config` to ever reach the
node.

Each node's static IP is set via a `LinkConfig` document keyed on the
interface **name** (`eno2` on all three boxes) rather than the older
`machine.network.interfaces[].deviceSelector.hardwareAddr` MAC-selector
approach — see
https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/linkconfig.
Hostnames use a `HostnameConfig` document the same way. These are
additional documents stacked into the same per-node patch file (separated
by `---`), applied through the same `--config-patch` flag as everything
else — no `Makefile`/tooling changes needed. `machine.install`/`nodeLabels`
have no document equivalent and stay under the classic `machine:` key.

## Layout

- `image/schematic.yaml` — Talos Image Factory system extensions
  (`i915-ucode`, `intel-ucode`, `iscsi-tools`, `util-linux-tools` — the
  last two are required by Longhorn).
- `bootstrap/cilium/` — Cilium install Job + Helm values, injected as
  Talos `inlineManifests` so Cilium comes up before kube-proxy/CNI would
  otherwise be needed (kube-proxy and the default CNI are disabled).
- `patches/machine.yaml` — shared config for every node (kubelet args,
  sysctls, region label).
- `patches/controlplane.yaml` — shared control-plane-only config
  (scheduling on control planes, CNI/kube-proxy disabled, extra
  manifests).
- `patches/nodes/ctrl-0X.yaml` — per-node `HostnameConfig` +
  `LinkConfig` (static IP/route on `eno2`), install disk, zone label.
- `scripts/` + `Makefile` — everything two things above can't express
  statically: looking up the Image Factory schematic ID, and rendering
  the Cilium manifests into `inlineManifests` strings.
- `generated/` — **gitignored**. `talosctl gen config` output (cluster
  PKI secrets!), the rendered dynamic patches, `talosconfig`,
  `kubeconfig`.

Run `make help` for the full target list.

## Prerequisites

`talosctl`, `kubectl`, `helm`, `python3`, `curl` on your machine.

## 1. Reserve each node's maintenance-mode IP

`patches/nodes/ctrl-01.yaml`, `ctrl-02.yaml`, `ctrl-03.yaml` already target
the `eno2` interface by name, so nothing needs editing there as long as
that's the right port on all three boxes.

**Recommended:** create a DHCP static reservation on your router for each
node's `eno2` MAC (check the NIC label, BIOS network page, or boot a Linux
live USB and run `ip link`), mapping it to the node's final static IP
(10.1.40.10/.11/.12). Talos maintenance mode uses DHCP before any config is
applied, and unlike the old Proxmox/cloud-init setup there's nothing to
push a static IP before boot — a reservation means the node is already
reachable at its final IP the moment it boots from USB, and
`talosctl apply-config` can target that IP directly.

## 2. Build and flash the install media

```bash
make iso-url
```

Download the printed ISO URL and flash it to a USB stick (balenaEtcher,
`dd`, Rufus, etc.). Boot each of the 3 machines from the USB stick into
Talos maintenance mode.

## 3. Apply config, bootstrap, fetch kubeconfig

Once all 3 nodes are up in maintenance mode and reachable at their static
IPs:

```bash
make apply-all   # pushes machine config + triggers install to /dev/nvme0n1 on all 3 nodes
make bootstrap   # one-time etcd bootstrap on ctrl-01
make kubeconfig  # writes generated/kubeconfig
make health      # waits for the cluster to report healthy
```

or just `make cluster` to run apply-all → bootstrap → health → flux in
one go (see below).

Use the generated config day to day:

```bash
export TALOSCONFIG=$(pwd)/generated/talosconfig
export KUBECONFIG=$(pwd)/generated/kubeconfig
```

> `make health` uses `talosctl health`; flag names have changed across
> Talos versions, so check `talosctl health --help` if it errors.

## 4. Bootstrap Flux and external-secrets

```bash
make flux                                          # installs flux-operator + applies k8s/bootstrap/flux
BITWARDEN_ACCESS_TOKEN=... make bitwarden-secret    # creates the token secret external-secrets needs
```

From here, deployment follows the rest of the repo as documented in
[../agents.md](../agents.md): Flux reconciles [../k8s/infra](../k8s/infra),
ArgoCD reconciles [../k8s/apps](../k8s/apps).

## Updating the cluster later

- Change `patches/*.yaml` for config changes, `image/schematic.yaml` for
  extensions, then re-run `make apply NODE=ctrl-01` (or `apply-all` for
  all three) — `talosctl apply-config` is safe to re-run against a live
  node.
- Bumping `TALOS_VERSION` and re-running `make render apply-all` upgrades
  the install image reference; Talos performs the actual OS upgrade on
  the next reboot/via `talosctl upgrade`.
