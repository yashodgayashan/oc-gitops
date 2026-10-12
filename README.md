# oc-gitops

Flux-managed install of OpenChoreo **v1.3.1** with every plane (control, data, workflow,
observability) in one cluster. After a one-time bootstrap, Git is the only source of
truth. The contents of this folder are the **root of the Git repo**.

Two cluster targets share the same modules:

| Target | For | Entry point |
|---|---|---|
| `k3d` | Local k3d cluster created by the bootstrap script, `*.openchoreo.localhost`, plain HTTP | `clusters/k3d` |
| `kubernetes` | Any existing cluster (EKS, GKE, AKS, kubeadm, ...), your own domains, TLS | `clusters/kubernetes` |

## Layout

```
bootstrap/                      one-time: (k3d cluster +) Flux + Git source
infrastructure/<module>/        shared prerequisites: namespaces, sources, gateway-api-crds,
                                cert-manager, trust-manager, external-secrets, kgateway, openbao, thunder
openchoreo/<module>/            shared OpenChoreo modules: control-plane, default-resources, data-plane,
                                workflow-plane, workflow-templates, observability-plane, observability-modules
clusters/<target>/
  infrastructure.yaml           Flux Kustomizations (one per module) and their dependsOn order
  openchoreo.yaml
  overlays/<module>/            what differs per target: Helm values, certificates, plane
                                registrations, target-only modules (k3d: coredns, registry;
                                kubernetes: tls)
```

A shared module holds what is the same everywhere: the HelmRelease (chart and version),
ExternalSecrets, the CA Bundle. Where a module needs per-target settings, the target's
`overlays/<module>/` includes the shared module (`../../../../openchoreo/<module>`) and
adds a `<module>-values` ConfigMap plus any extra manifests. Flux points at the overlay
for those modules and directly at the shared module for the rest.

Install order (both targets; `coredns` is k3d-only, `tls` is kubernetes-only):

```
namespaces, sources, gateway-api-crds, [coredns]
  ├─ cert-manager ─┬─ trust-manager ────────────┐
  │                └─ [tls] ────────────────────┤
  ├─ external-secrets ── openbao ───────────────┤
  ├─ kgateway ──────────────────────────────────┼─ control-plane ─┬─ default-resources
  └─ thunder ───────────────────────────────────┘                 ├─ data-plane
                                                                  ├─ workflow-plane ── workflow-templates
                                                                  └─ observability-plane ── observability-modules
```

## Target: k3d

Values are the upstream `install/k3d/...` files at tag `v1.3.1`, copied unchanged into
`clusters/k3d/overlays/`.

Prerequisites: `k3d`, `kubectl`, `flux` (`brew install fluxcd/tap/flux`), Docker or Colima.
The k3d config uses the same host ports as the upstream `openchoreo` cluster (8080,
19080, ...), so stop that cluster first: `k3d cluster stop openchoreo`.

```bash
bootstrap/bootstrap.sh --git-url https://github.com/<you>/oc-gitops
flux --context k3d-oc-gitops get kustomizations --watch
```

A cold install takes about 15 minutes. Console: http://openchoreo.localhost:8080
(`admin@openchoreo.dev` / `Admin@123`). API: http://api.openchoreo.localhost:8080.

## Target: kubernetes

Follows the upstream "On Your Environment" guide, turned into manifests.

1. **Edit `clusters/kubernetes/cluster-settings.yaml`** with three domains:
   `CP_BASE_DOMAIN` (console/api/thunder), `DP_DOMAIN` (deployed apps) and
   `OBS_BASE_DOMAIN` (observer/agents). Flux substitutes them into the thunder,
   control-plane, data-plane and observability-plane modules (`postBuild`). Commit and push.
2. **Bootstrap** against a cluster you already have:
   ```bash
   bootstrap/bootstrap.sh --cluster kubernetes --context <kube-context> \
     --git-url https://github.com/<you>/oc-gitops
   ```
3. **Point DNS** (each domain and its wildcard) at the matching `gateway-default`
   LoadBalancer in `openchoreo-control-plane`, `openchoreo-data-plane` and
   `openchoreo-observability-plane`. Without your own DNS, use nip.io: bootstrap, read
   the LoadBalancer IPs, set e.g. `openchoreo.203-0-113-10.nip.io`, then push.

What differs from k3d:

| Area | kubernetes target |
|---|---|
| TLS | `overlays/tls`: a self-signed CA (`ClusterIssuer openchoreo-ca`) issues a wildcard certificate for each gateway. Switch to a trusted issuer by replacing that ClusterIssuer, then remove `skip_tls_verify` and `NODE_TLS_REJECT_UNAUTHORIZED` from `overlays/control-plane/values.yaml`. |
| DNS | No CoreDNS rewrite. Real DNS records are required. |
| Server-to-server calls | Observer, RCA/FinOps agents, portal assistant and build pods call the API, observer and Thunder through in-cluster Service URLs, so self-signed certificates don't get in the way. |
| Build images | No in-cluster registry. `publish-image` pushes to ttl.sh (anonymous, 24h expiry). Replace `overlays/workflow-templates/publish-image.yaml` with one for your registry. |
| `occ remote`, Argo UI LoadBalancer | Not enabled. |
| Gateway ports | 80/443 on each plane gateway. If your LoadBalancer gives all gateways one IP, set different `gateway.httpPort/httpsPort` per plane and match them in `cluster-data-plane.yaml`. |

Variable substitution is deliberately **not** enabled on `default-resources`,
`workflow-templates` or `observability-modules`, because they contain literal `${...}`
(CEL expressions, shell, OTel config) that Flux would otherwise rewrite.

## How the imperative install steps map (both targets)

| Upstream step | Here |
|---|---|
| `kubectl apply` Gateway API CRDs, CoreDNS rewrite, `all.yaml`, workflow templates | Plain manifests in modules |
| `openbao/setup.sh` (k8s auth, policies, seeded secrets) | OpenBao chart `postStart` from upstream `values-openbao.yaml`, plus `ClusterSecretStore` |
| `kubectl create secret backstage-secrets` | `ExternalSecret` (OpenBao-backed) |
| Copy `cluster-gateway-ca` into each plane namespace | trust-manager `Bundle` → namespaces labelled `oc-gitops/cluster-gateway-ca=true` |
| Register planes with the agent CA inlined | `clientCA.secretKeyRef` → each plane's `cluster-agent-tls` Secret |
| `kubectl patch ... observabilityPlaneRef` | Set directly in the `ClusterDataPlane` / `ClusterWorkflowPlane` specs |
| Self-signed CA + gateway certificates (generic guide) | `clusters/kubernetes/overlays/tls` + one `Certificate` per plane overlay |
| `docker exec ... /etc/machine-id` (k3d) | `bootstrap/bootstrap.sh` |

trust-manager is the one component the upstream install does not use.

## Day-2

- **Upgrade OpenChoreo**: bump `version:` in the shared plane HelmReleases (and the
  module versions), then diff the vendored files (`clusters/k3d/overlays/*/values*.yaml`,
  `getting-started.yaml`, workflow templates) against the new tag. Carry relevant changes
  into the kubernetes overlays too.
- **Add another target** (e.g. `clusters/staging`): copy `clusters/kubernetes`, change
  `cluster-settings.yaml`, and bootstrap with `--cluster staging`.
- **Drop a plane**: remove its entries from `clusters/<target>/openchoreo.yaml`. If you drop
  observability, also remove `observabilityPlaneRef` from the data/workflow plane
  registrations and the `audit` override in the control-plane HelmRelease.
- **Secrets**: OpenBao runs in dev mode on **both** targets (in-memory, root token `root`;
  placeholders re-seeded on every restart). Before real use on the kubernetes target,
  replace `infrastructure/openbao` with a production OpenBao/Vault or your cloud secret
  manager behind a `ClusterSecretStore` named `default` holding the same keys.

## Not included

- Planes in separate clusters. The CA Bundle and `secretKeyRef` registration assume one cluster.
- `push-buildpack-cache-images` Job, registry-cache patches, build-cache (zot).
- KEDA, WSO2 API Platform gateway, or anything else outside the upstream install.
