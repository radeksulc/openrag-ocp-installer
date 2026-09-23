#!/usr/bin/env bash
# Cleanly tears down everything install.sh created.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
: "${NAMESPACE:=openrag}"

log() { echo "==> $*"; }

oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged into a cluster. Run 'oc login ...' first." >&2; exit 1; }

read -r -p "This deletes the '$NAMESPACE' project and all data in it. Type the namespace name to confirm: " CONFIRM
if [ "$CONFIRM" != "$NAMESPACE" ]; then
  echo "Aborted."
  exit 1
fi

log "Deleting the OpenRAG CR (lets the operator finalize/clean up first)..."
oc delete openrag openrag -n "$NAMESPACE" --ignore-not-found --timeout=120s || true

log "Uninstalling the operator..."
helm uninstall openrag-operator -n "$NAMESPACE" 2>/dev/null || true

log "Deleting the project (removes Postgres, OpenSearch, secrets, PVCs, Routes, ServiceAccounts, everything else in it)..."
oc delete project "$NAMESPACE" --ignore-not-found

log "Deleting the cluster-scoped CRD..."
oc delete crd openrags.openr.ag --ignore-not-found

log "Removing the anyuid SCC grant (no-op if the namespace/SA is already gone)..."
oc adm policy remove-scc-from-user anyuid -z openrag-opensearch -n "$NAMESPACE" 2>/dev/null || true

log "Done."
