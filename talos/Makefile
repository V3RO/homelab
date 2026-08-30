SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

CLUSTER_NAME     ?= talos
TALOS_VERSION    ?= v1.13.7
FACTORY_URL      ?= https://factory.talos.dev
PLATFORM         ?= metal
ARCH             ?= amd64

CTRL01_IP        ?= 10.1.40.10
CTRL02_IP        ?= 10.1.40.11
CTRL03_IP        ?= 10.1.40.12
CLUSTER_ENDPOINT ?= https://$(CTRL01_IP):6443

GENERATED := generated
TALOSCONFIG := $(GENERATED)/talosconfig

.DEFAULT_GOAL := help

.PHONY: help schematic-id iso-url render genconfig \
        apply apply-all \
        bootstrap kubeconfig health flux bitwarden-secret cluster clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "%-18s %s\n", $$1, $$2}'

schematic-id: ## Look up the Image Factory schematic ID for image/schematic.yaml
	mkdir -p $(GENERATED)
	FACTORY_URL=$(FACTORY_URL) ./scripts/schematic-id.sh > $(GENERATED)/schematic-id.txt
	@echo "Schematic ID: $$(cat $(GENERATED)/schematic-id.txt)"

iso-url: schematic-id ## Print the metal ISO URL to download and flash to a USB stick
	@echo "$(FACTORY_URL)/image/$$(cat $(GENERATED)/schematic-id.txt)/$(TALOS_VERSION)/$(PLATFORM)-$(ARCH).iso"

render: schematic-id ## Render the dynamic patches (install image + Cilium inline manifests)
	TALOS_VERSION=$(TALOS_VERSION) python3 scripts/render-patches.py

genconfig: ## Generate cluster secrets + base controlplane/worker config + talosconfig
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) --output-dir $(GENERATED) --force

# Requires the target node to already be booted from the USB stick into
# Talos maintenance mode and reachable at its static IP (set a DHCP
# reservation for its MAC so maintenance mode already gets that IP).
apply: render genconfig ## Apply config to one node: make apply NODE=ctrl-01 [IP=10.1.40.10]
	@if [ -z "$(NODE)" ]; then \
	  echo "Usage: make apply NODE=ctrl-01 [IP=10.1.40.10]" >&2; exit 1; \
	fi
	@ip="$(IP)"; \
	if [ -z "$$ip" ]; then \
	  case "$(NODE)" in \
	    ctrl-01) ip="$(CTRL01_IP)" ;; \
	    ctrl-02) ip="$(CTRL02_IP)" ;; \
	    ctrl-03) ip="$(CTRL03_IP)" ;; \
	    *) echo "Unknown NODE '$(NODE)', pass IP=... explicitly" >&2; exit 1 ;; \
	  esac; \
	fi; \
	talosctl apply-config --insecure --nodes "$$ip" \
	  --file $(GENERATED)/controlplane.yaml \
	  --config-patch @patches/machine.yaml \
	  --config-patch @$(GENERATED)/install-image.yaml \
	  --config-patch @patches/controlplane.yaml \
	  --config-patch @$(GENERATED)/cilium-inline-manifests.yaml \
	  --config-patch @patches/nodes/$(NODE).yaml

apply-all: render genconfig ## Apply config to all 3 control-plane nodes
	$(MAKE) apply NODE=ctrl-01 IP=$(CTRL01_IP)
	$(MAKE) apply NODE=ctrl-02 IP=$(CTRL02_IP)
	$(MAKE) apply NODE=ctrl-03 IP=$(CTRL03_IP)

bootstrap: ## Bootstrap etcd on the first control-plane node (one-time)
	talosctl --talosconfig $(TALOSCONFIG) bootstrap --nodes $(CTRL01_IP)

kubeconfig: ## Fetch the kubeconfig into generated/kubeconfig
	talosctl --talosconfig $(TALOSCONFIG) kubeconfig --nodes $(CTRL01_IP) --force $(GENERATED)

health: ## Wait for the cluster to report healthy (check `talosctl health --help` for your version's flags)
	talosctl --talosconfig $(TALOSCONFIG) health \
	  --control-plane-nodes $(CTRL01_IP),$(CTRL02_IP),$(CTRL03_IP)

flux: ## Install/upgrade the Flux Operator and apply the Flux bootstrap kustomization (safe to re-run)
	KUBECONFIG=$(GENERATED)/kubeconfig helm upgrade --install flux-operator \
	  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
	  -n flux-system --create-namespace
	KUBECONFIG=$(GENERATED)/kubeconfig kubectl apply --server-side -k ../k8s/bootstrap/flux

bitwarden-secret: ## Create the Bitwarden access-token secret used by external-secrets (needs BITWARDEN_ACCESS_TOKEN)
	KUBECONFIG=$(GENERATED)/kubeconfig ./scripts/create-bitwarden-secret.sh

cluster: apply-all bootstrap health flux ## Full bring-up once all 3 nodes are booted in maintenance mode

clean: ## Remove generated files (WARNING: deletes cluster secrets, kubeconfig, talosconfig)
	rm -rf $(GENERATED)
