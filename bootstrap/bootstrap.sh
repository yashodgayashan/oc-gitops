#!/usr/bin/env bash
# One-time, imperative bootstrap: everything after this is reconciled by Flux.
#   1. create the k3d cluster        (k3d-config.yaml = upstream single-cluster config, renamed)
#   2. give the node a machine-id     (Fluent Bit in the logs module needs it)
#   3. install the Flux controllers
#   4. point Flux at this repo        (flux-sync.yaml)
#
# Usage: bootstrap/bootstrap.sh --git-url https://github.com/<you>/oc-gitops [--branch main]
set -euo pipefail

GIT_URL=""
GIT_BRANCH="main"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="$(awk '/^metadata:/{m=1} m&&/name:/{print $2; exit}' "$DIR/k3d-config.yaml")"

while [[ $# -gt 0 ]]; do
  case $1 in
    --git-url) GIT_URL="$2"; shift 2 ;;
    --branch)  GIT_BRANCH="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$GIT_URL" ]] || { echo "--git-url is required" >&2; exit 1; }
for t in k3d kubectl flux; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

if ! k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
  # Colima: k3d's DNS fix breaks host.k3d.internal (k3d-io/k3d#1449).
  K3D_FIX_DNS="${K3D_FIX_DNS:-0}" k3d cluster create --config "$DIR/k3d-config.yaml"
fi
CTX="k3d-$CLUSTER_NAME"

docker exec "k3d-$CLUSTER_NAME-server-0" sh -c \
  "[ -s /etc/machine-id ] || cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id"

flux install --context "$CTX"

sed -e "s|\${GIT_URL}|$GIT_URL|" -e "s|\${GIT_BRANCH}|$GIT_BRANCH|" "$DIR/flux-sync.yaml" \
  | kubectl --context "$CTX" apply -f -

echo
echo "Flux is syncing $GIT_URL ($GIT_BRANCH). Watch progress with:"
echo "  flux --context $CTX get kustomizations --watch"
