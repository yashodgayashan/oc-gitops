# oc-gitops

Flux-managed install of OpenChoreo **v1.3.1** on a single local k3d cluster: control,
data, workflow and observability planes. After a one-time bootstrap, Git is the only
source of truth.

This README assumes the contents of this folder are the **root of the Git repo**.

## Layout

```
bootstrap/                 one-time, imperative (k3d cluster + Flux + Git source)
clusters/k3d/              entry point: one Flux Kustomization per module, wired with dependsOn
infrastructure/<module>/   prerequisites: namespaces, sources, gateway-api-crds, coredns,
                           cert-manager, trust-manager, external-secrets, kgateway, openbao, thunder
openchoreo/<module>/       control-plane, default-resources, data-plane, workflow-plane,
                           workflow-templates, observability-plane, observability-modules
```

Each `<module>/` directory is one Flux `Kustomization`. A module is either a HelmRelease
plus its values, or plain manifests. Install order is defined only in
`clusters/k3d/*.yaml`:

```
namespaces, sources, gateway-api-crds, coredns
  ├─ cert-manager ── trust-manager ─────────────┐
  ├─ external-secrets ── openbao ───────────────┤
  ├─ kgateway ──────────────────────────────────┼─ control-plane ─┬─ default-resources
  └─ thunder ───────────────────────────────────┘                 ├─ data-plane
                                                                  ├─ workflow-plane ── workflow-templates
                                                                  └─ observability-plane ── observability-modules
```

`values.yaml` files are copied unchanged from the upstream repo at tag `v1.3.1`
(`install/k3d/...`). Each HelmRelease names the upstream file it came from, so you can
diff it against a newer release when upgrading. Overrides go in the HelmRelease's
inline `values:` block, which takes precedence over `valuesFrom`.

## How the imperative install steps map

| Upstream step (k3d README / k3d-install.sh) | Here |
|---|---|
| `kubectl apply` Gateway API CRDs, CoreDNS rewrite, `all.yaml`, workflow templates | Plain manifests in modules |
| `openbao/setup.sh` (k8s auth, policies, seeded secrets) | OpenBao chart `postStart` from upstream `values-openbao.yaml`, plus `ClusterSecretStore` |
| `kubectl create secret backstage-secrets` | `ExternalSecret` (OpenBao-backed) |
| Copy `cluster-gateway-ca` into each plane namespace | trust-manager `Bundle` → namespaces labelled `oc-gitops/cluster-gateway-ca=true` |
| Register planes with the agent CA inlined | `clientCA.secretKeyRef` → each plane's `cluster-agent-tls` Secret |
| `kubectl patch ... observabilityPlaneRef` | Set directly in the `ClusterDataPlane` / `ClusterWorkflowPlane` specs |
| `docker exec ... /etc/machine-id` | `bootstrap/bootstrap.sh` (node-level, cannot be done from Git) |

trust-manager is the one component the upstream install does not use.

## Bootstrap

Prerequisites: `k3d`, `kubectl`, `flux` (`brew install fluxcd/tap/flux`), Docker or Colima.

The k3d config uses the same host ports as the upstream `openchoreo` cluster (8080,
19080, ...), so stop that cluster first: `k3d cluster stop openchoreo`.

```bash
git push   # Flux pulls from the remote, not from this folder
bootstrap/bootstrap.sh --git-url https://github.com/<you>/oc-gitops --branch main
flux --context k3d-oc-gitops get kustomizations --watch
```

For a private repo, see the note in `bootstrap/flux-sync.yaml`.

A cold install takes roughly 15–30 minutes. Most of that is image pulls and the
observability plane. Once every Kustomization is `Ready`, use the same URLs as the
upstream guide: console at http://openchoreo.localhost:8080
(`admin@openchoreo.dev` / `Admin@123`), API at http://api.openchoreo.localhost:8080.

## Day-2

- **Upgrade OpenChoreo**: bump `version:` in the plane HelmReleases (and the module
  versions), then diff the vendored `values.yaml` files and `getting-started.yaml`
  against the new tag.
- **Drop a plane**: remove its entries from `clusters/k3d/openchoreo.yaml`. If you drop
  observability, also remove `observabilityPlaneRef` from the data/workflow plane
  registrations, and the `audit` override in the control-plane HelmRelease.
- **Real secrets**: OpenBao runs in dev mode (in-memory, root token `root`), and its
  `postStart` re-seeds placeholders on every restart. Put real values in your own store
  or a SOPS-encrypted overlay. Don't commit them into `values.yaml`.

## Not included

- `push-buildpack-cache-images` Job, registry-cache patches, build-cache (zot).
- KEDA, WSO2 API Platform gateway, or anything else installed on the old cluster
  outside the upstream k3d install.
