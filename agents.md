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
The k8s cluster is deployed using argocd and the applications are managed using two argocd applicationsets (infra and apps). Therefore, don't use kubectl (or Helm) to deploy applications to the cluster.
- Infrastructure services are defined in the [k8s/infra](./k8s/infra) directory following the structure `k8s/infra/[namespace]/[application]`. The infra ApplicationSet uses progressive sync (RollingSync) to ensure correct deployment ordering.
- User-facing applications are defined in the [k8s/apps](./k8s/apps) directory following the structure `k8s/apps/[namespace]/[application]`.

### Platform Services
The cluster already provides services for caching, database, DNS, and secret handling that can and should be used by other the applications if they need it (e.g. for caching or database).
- [Cache](./k8s/infra/valkey)
- [Database](./k8s/infra/cnpg)
- [External Secrets (uses Bitwarden)](./k8s/infra/external-secrets)
- [Authentication](./k8s/apps/authentik)
- Ingress:
  - Use Kubernetes Gateway API
  - Istio is used for service mesh and handles ingress
  - [external-dns](./k8s/infra/external-dns) is used to create DNS records
  - [cert-manager](./k8s/infra/cert-manager) is used to create TLS certificates

