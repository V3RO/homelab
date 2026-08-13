# Homelab
Repository containing my complete homelab setup

## Structure
- [k8s](./k8s) containing all homelab cluster deployments
- [tofu](./tofu/kubernetes) containing the open tofu projects for the talos kubernetes cluster
- [tofu](./tofu/home-assistant) containing the open tofu projects my Home Assistant VM

### Kubernetes Cluster

To interact with the k8s cluster use the kubeconfig output from open tofu project
```bash
kubectl --kubeconfig tofu/kubernetes/output/kube-config.yaml get pods
```

### Deployment
The cluster is bootstrapped by open tofu ([flux.tofu](./tofu/kubernetes/flux.tofu)) which installs Flux and applies [k8s/bootstrap/flux](./k8s/bootstrap/flux). From there deployment is split:
- Infrastructure services are defined in [k8s/infra](./k8s/infra) following the structure `k8s/infra/[namespace]/[application]` and are reconciled by Flux. Each component has its own Flux `Kustomization` in [k8s/bootstrap/flux/components](./k8s/bootstrap/flux/components) with `dependsOn` edges forming the deployment-order DAG (health-gated on the component's HelmRelease). When adding an infra component, add a Kustomization there with the correct edges.
- User-facing applications are defined in [k8s/apps](./k8s/apps) following the structure `k8s/apps/[namespace]/[application]` and are managed by ArgoCD via the `apps` ApplicationSet (deployed by Flux as the last infra component in `70-argo.yaml`).

Don't use kubectl (or Helm) to deploy applications to the cluster.

### Platform Services
The cluster already provides services for caching, database, DNS, and secret handling that can and should be used by other the applications if they need it (e.g. for caching or database).
- [Cache](./k8s/infra/valkey)
- [Database](./k8s/infra/cnpg)
- [External Secrets (uses Bitwarden)](./k8s/infra/external-secrets)
- [Authentication](k8s/infra/authentik)
- Ingress:
  - Use Kubernetes Gateway API
  - Istio is used for service mesh and handles ingress
  - [external-dns](./k8s/infra/external-dns) is used to create DNS records
  - [cert-manager](./k8s/infra/cert-manager) is used to create TLS certificates

