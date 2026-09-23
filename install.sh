#!/usr/bin/env bash
# Repeatable OpenRAG installer for OpenShift (operator path), with every
# workaround discovered during a live deployment baked in from the start.
# See README.md for background on each fix, and
# kubernetes/OPENSHIFT_DEPLOYMENT_NOTES.md in langflow-ai/openrag for the
# full write-up submitted upstream.
#
# Usage:
#   oc login ...            # log into the target cluster yourself first
#   cp .env.example .env && edit .env
#   ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env, fill it in, then rerun." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${OPENAI_API_KEY:?Set OPENAI_API_KEY in .env}"
: "${NAMESPACE:=openrag}"
: "${OPENRAG_REPO_REF:=main}"
: "${LLM_MODEL:=gpt-4o-mini}"
: "${EMBEDDING_MODEL:=text-embedding-3-large}"
: "${ENABLE_DOCLING:=true}"
: "${CREATE_ROUTES:=true}"

log()  { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "Checking prerequisites..."
for bin in oc helm git openssl python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged into a cluster. Run 'oc login ...' first." >&2; exit 1; }
log "Logged in as $(oc whoami) against $(oc whoami --show-server)"

# ---------------------------------------------------------------------------
# Get the operator/Helm chart source
# ---------------------------------------------------------------------------
if [ -z "${OPENRAG_REPO_PATH:-}" ]; then
  OPENRAG_REPO_PATH="$SCRIPT_DIR/openrag-src"
  if [ ! -d "$OPENRAG_REPO_PATH/.git" ]; then
    log "Cloning langflow-ai/openrag@$OPENRAG_REPO_REF into $OPENRAG_REPO_PATH ..."
    git clone --depth 1 --branch "$OPENRAG_REPO_REF" https://github.com/langflow-ai/openrag.git "$OPENRAG_REPO_PATH"
  else
    log "Reusing existing clone at $OPENRAG_REPO_PATH"
  fi
fi
CRD_FILE="$OPENRAG_REPO_PATH/kubernetes/operator/config/crd/bases/openr.ag_openrags.yaml"
OPERATOR_CHART="$OPENRAG_REPO_PATH/kubernetes/helm/operator"
[ -f "$CRD_FILE" ] || { echo "ERROR: CRD not found at $CRD_FILE -- check OPENRAG_REPO_PATH/OPENRAG_REPO_REF." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
if oc get project "$NAMESPACE" >/dev/null 2>&1; then
  log "Project $NAMESPACE already exists, reusing it."
else
  log "Creating project $NAMESPACE ..."
  oc new-project "$NAMESPACE" >/dev/null
fi
oc project "$NAMESPACE" >/dev/null

# ---------------------------------------------------------------------------
# Storage class
# ---------------------------------------------------------------------------
if [ -z "${STORAGE_CLASS:-}" ]; then
  STORAGE_CLASS="$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' | awk '{print $1}')"
  [ -n "$STORAGE_CLASS" ] || { echo "ERROR: no default StorageClass found; set STORAGE_CLASS in .env explicitly." >&2; exit 1; }
fi
log "Using StorageClass: $STORAGE_CLASS"

# ---------------------------------------------------------------------------
# CRD (oc create, not apply -- the CRD is too large for the client-side
# last-applied-configuration annotation; see notes doc §3.1)
# ---------------------------------------------------------------------------
if oc get crd openrags.openr.ag >/dev/null 2>&1; then
  log "CRD openrags.openr.ag already present, skipping."
else
  log "Installing CRD..."
  oc create -f "$CRD_FILE"
fi

# ---------------------------------------------------------------------------
# Operator (Helm)
# ---------------------------------------------------------------------------
log "Installing/upgrading the operator via Helm..."
helm upgrade --install openrag-operator "$OPERATOR_CHART" -n "$NAMESPACE"

log "Waiting for the operator to be ready..."
oc rollout status deployment/openrag-operator -n "$NAMESPACE" --timeout=180s

# ---------------------------------------------------------------------------
# Fix operator RBAC: the Helm chart's ClusterRole is missing permissions
# present in the kustomize source (needed for the Valkey StatefulSet and any
# HPA usage). See notes doc §4 / "chart drift".
# ---------------------------------------------------------------------------
log "Patching operator ClusterRole (statefulsets, hpa)..."
CR_NAME="openrag-operator-manager-role"
python3 - "$CR_NAME" <<'PYEOF'
import json, subprocess, sys
name = sys.argv[1]
out = subprocess.run(["oc", "get", "clusterrole", name, "-o", "json"], capture_output=True, text=True, check=True)
d = json.loads(out.stdout)
have = {tuple(sorted(r.get("apiGroups", []) + r.get("resources", []))) for r in d["rules"]}
needed = [
    {"apiGroups": ["apps"], "resources": ["statefulsets"], "verbs": ["create","delete","get","list","patch","update","watch"]},
    {"apiGroups": ["autoscaling"], "resources": ["horizontalpodautoscalers"], "verbs": ["create","delete","get","list","patch","update","watch"]},
]
changed = False
for rule in needed:
    key = tuple(sorted(rule["apiGroups"] + rule["resources"]))
    if key not in have:
        d["rules"].append(rule)
        changed = True
if changed:
    subprocess.run(["oc", "replace", "-f", "-"], input=json.dumps(d), text=True, check=True)
    print("ClusterRole patched.")
else:
    print("ClusterRole already has the needed rules.")
PYEOF

# ---------------------------------------------------------------------------
# Secrets (idempotent: only generate if missing, so reruns never rotate the
# JWT signing key -- rotating it after the fact requires manually deleting
# operator-managed default secrets; see notes doc §3.10)
# ---------------------------------------------------------------------------
ensure_secret_literal() {
  local name="$1"; shift
  if oc get secret "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Secret $name already exists, leaving it alone."
  else
    log "Creating secret $name..."
    oc create secret generic "$name" -n "$NAMESPACE" "$@"
  fi
}

if ! oc get secret openrag-postgres-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  PG_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  ensure_secret_literal openrag-postgres-credentials \
    --from-literal=POSTGRESQL_USER=langflow \
    --from-literal=POSTGRESQL_PASSWORD="$PG_PASS" \
    --from-literal=POSTGRESQL_DATABASE=langflow
  ensure_secret_literal openrag-langflow-db \
    --from-literal=LANGFLOW_DATABASE_URL="postgresql://langflow:${PG_PASS}@openrag-postgres:5432/langflow"
  unset PG_PASS
else
  log "Postgres credentials already exist, leaving them alone."
fi

if ! oc get secret openrag-opensearch-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  OS_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)Aa1!"
  ensure_secret_literal openrag-opensearch-credentials \
    --from-literal=username=admin \
    --from-literal=password="$OS_PASS"
  unset OS_PASS
fi

ensure_secret_literal openrag-llm-credentials --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY"

# The operator's auto-generated JWT_SIGNING_KEY default is a plain symmetric
# string, not an RSA key -- which leaves /auth/jwks permanently empty and
# breaks every per-user OpenSearch call under this OpenSearch security
# config (RS256 JWT auth). Generate a real RSA key up front, before the
# operator ever reconciles, so the "immutable after first use" guard never
# comes into play. See notes doc §3.10.
if ! oc get secret openrag-jwt-signing-key -n "$NAMESPACE" >/dev/null 2>&1; then
  log "Generating RSA JWT signing key..."
  TMPKEY="$(mktemp -d)"
  openssl genrsa -out "$TMPKEY/private_key.pem" 2048 >/dev/null 2>&1
  oc create secret generic openrag-jwt-signing-key -n "$NAMESPACE" \
    --from-file=JWT_SIGNING_KEY="$TMPKEY/private_key.pem"
  oc patch secret openrag-jwt-signing-key -n "$NAMESPACE" -p '{"immutable": true}' --type=merge >/dev/null
  shred -u "$TMPKEY/private_key.pem" 2>/dev/null || rm -f "$TMPKEY/private_key.pem"
  rmdir "$TMPKEY"
else
  log "JWT signing key already exists, leaving it alone."
fi

# ---------------------------------------------------------------------------
# PostgreSQL (not deployed by the operator or Helm chart at all)
# ---------------------------------------------------------------------------
log "Deploying PostgreSQL..."
if oc get imagestream postgresql -n openshift >/dev/null 2>&1; then
  PG_IMAGE="image-registry.openshift-image-registry.svc:5000/openshift/postgresql:15-el9"
else
  warn "No 'postgresql' ImageStream found in the 'openshift' namespace on this cluster."
  warn "Falling back to registry.redhat.io/rhel9/postgresql-16 -- this requires a Red Hat pull secret."
  warn "Set PG_IMAGE in .env to override if this doesn't work on your cluster."
  PG_IMAGE="${PG_IMAGE:-registry.redhat.io/rhel9/postgresql-16:latest}"
fi

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openrag-postgres-data
  namespace: $NAMESPACE
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: $POSTGRES_STORAGE_SIZE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openrag-postgres
  namespace: $NAMESPACE
  labels:
    app: openrag-postgres
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: openrag-postgres
  template:
    metadata:
      labels:
        app: openrag-postgres
    spec:
      containers:
        - name: postgres
          image: $PG_IMAGE
          ports:
            - containerPort: 5432
              name: postgres
          envFrom:
            - secretRef:
                name: openrag-postgres-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/pgsql/data
          resources:
            requests: {cpu: "250m", memory: "512Mi"}
            limits: {cpu: "1", memory: "1Gi"}
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "langflow"]}
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            exec: {command: ["pg_isready", "-U", "langflow"]}
            initialDelaySeconds: 30
            periodSeconds: 20
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openrag-postgres-data
---
apiVersion: v1
kind: Service
metadata:
  name: openrag-postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: openrag-postgres
  ports:
    - port: 5432
      targetPort: 5432
EOF

# ---------------------------------------------------------------------------
# OpenSearch (must be langflowai/openrag-opensearch -- the backend hardcodes
# the "jvector" k-NN engine, which only this image's OpenSearch has; see
# notes doc §2). Runs under a dedicated SA + anyuid SCC + runAsUser: 1000 --
# the image's own security-bootstrap script chowns its securityconfig/
# directory to UID/GID 1000 (not group 0 like the rest of the image), so it
# needs to run as UID 1000 specifically or its admin-password bootstrap
# silently fails under OpenShift's arbitrary-UID SCC. See notes doc §3.5.
# ---------------------------------------------------------------------------
log "Deploying OpenSearch..."
if ! oc get sa openrag-opensearch -n "$NAMESPACE" >/dev/null 2>&1; then
  oc create serviceaccount openrag-opensearch -n "$NAMESPACE"
fi
oc adm policy add-scc-to-user anyuid -z openrag-opensearch -n "$NAMESPACE" >/dev/null

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openrag-opensearch-data
  namespace: $NAMESPACE
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: $OPENSEARCH_STORAGE_SIZE
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openrag-opensearch
  namespace: $NAMESPACE
  labels:
    app: openrag-opensearch
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: openrag-opensearch
  template:
    metadata:
      labels:
        app: openrag-opensearch
    spec:
      serviceAccountName: openrag-opensearch
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: opensearch
          image: docker.io/langflowai/openrag-opensearch:latest
          ports:
            - containerPort: 9200
              name: https
            - containerPort: 9600
              name: perf
          env:
            - name: discovery.type
              value: single-node
            - name: OPENSEARCH_JAVA_OPTS
              value: "-Xms1g -Xmx1g"
            - name: OPENRAG_BACKEND_HOST
              value: openrag-be
            - name: OPENRAG_BACKEND_PORT
              value: "8000"
            - name: OPENRAG_BACKEND_INTERNAL_URL
              value: "http://openrag-be.$NAMESPACE.svc.cluster.local:8000"
            - name: OPENSEARCH_INITIAL_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openrag-opensearch-credentials
                  key: password
          volumeMounts:
            - name: data
              mountPath: /usr/share/opensearch/data
          resources:
            requests: {cpu: "500m", memory: "2Gi"}
            limits: {cpu: "2", memory: "3Gi"}
          readinessProbe:
            tcpSocket: {port: 9200}
            initialDelaySeconds: 60
            periodSeconds: 15
            failureThreshold: 10
          livenessProbe:
            tcpSocket: {port: 9200}
            initialDelaySeconds: 90
            periodSeconds: 20
            failureThreshold: 6
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: openrag-opensearch-data
---
apiVersion: v1
kind: Service
metadata:
  name: openrag-opensearch
  namespace: $NAMESPACE
spec:
  selector:
    app: openrag-opensearch
  ports:
    - {name: https, port: 9200, targetPort: 9200}
    - {name: perf, port: 9600, targetPort: 9600}
EOF

log "Waiting for PostgreSQL and OpenSearch to become ready (this can take a couple of minutes)..."
oc rollout status deployment/openrag-postgres -n "$NAMESPACE" --timeout=300s
oc rollout status deployment/openrag-opensearch -n "$NAMESPACE" --timeout=300s

# ---------------------------------------------------------------------------
# Routes (created before the CR so LANGFLOW_PUBLIC_URL can be set correctly
# from the start -- see notes doc §3.11. Routes can reference a Service name
# before that Service exists.)
# ---------------------------------------------------------------------------
FRONTEND_HOST=""
LANGFLOW_HOST=""
if [ "$CREATE_ROUTES" = "true" ]; then
  log "Creating Routes..."
  if ! oc get route openrag-frontend -n "$NAMESPACE" >/dev/null 2>&1; then
    oc create route edge openrag-frontend -n "$NAMESPACE" --service=openrag-fe --port=3000 --insecure-policy=Redirect >/dev/null
  fi
  if ! oc get route openrag-langflow -n "$NAMESPACE" >/dev/null 2>&1; then
    oc create route edge openrag-langflow -n "$NAMESPACE" --service=openrag-lf --port=7860 --insecure-policy=Redirect >/dev/null
  fi
  FRONTEND_HOST="$(oc get route openrag-frontend -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
  LANGFLOW_HOST="$(oc get route openrag-langflow -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
  log "Frontend will be at: https://$FRONTEND_HOST"
  log "Langflow will be at:  https://$LANGFLOW_HOST"
fi

# ---------------------------------------------------------------------------
# The OpenRAG CR
#
# Fixes baked in (see kubernetes/OPENSHIFT_DEPLOYMENT_NOTES.md in
# langflow-ai/openrag for the full explanation of each):
#   - langflow.command/args: bypass the operator's default `langflow` command
#     (doesn't exist on PATH in this image) AND the image's own entrypoint
#     wrapper (assumes it starts as root, which OpenShift's SCC never allows)
#   - LANGFLOW_WORKERS=1: the image refuses 4 workers without a shared
#     (Redis/Valkey) job queue
#   - no flowsRef: setting it unconditionally overwrites the image's bundled,
#     compatible flows with whatever's on that git ref -- which can reference
#     custom components the published image doesn't actually have
#   - OPENSEARCH_NODE_COUNT_CHECK_ENABLED=false etc.: single-node OpenSearch
#     doesn't meet the multi-node (3x) readiness defaults
#   - INGEST_SAMPLE_DATA=false: onboarding's sample-doc ingestion runs as an
#     anonymous user with no JWT and always 401s against this OpenSearch
#     security config
#   - jwtSigningKeySecret: real RSA key, set from the very first reconcile
#     (see the secrets section above)
#   - LANGFLOW_PUBLIC_URL: points "Open in Langflow" at the real Route
#     instead of a same-host:7860 fallback that doesn't exist behind a Route
# ---------------------------------------------------------------------------
log "Applying the OpenRAG CR..."

LANGFLOW_PUBLIC_URL_ENV=""
if [ -n "$LANGFLOW_HOST" ]; then
  LANGFLOW_PUBLIC_URL_ENV="      - name: LANGFLOW_PUBLIC_URL
        value: \"https://$LANGFLOW_HOST\""
fi

DOCLING_BLOCK=""
if [ "$ENABLE_DOCLING" = "true" ]; then
  DOCLING_BLOCK="
  doclingComponents:
    enabled: true
    serve:
      image: ghcr.io/docling-project/docling-serve-cpu:v1.15.1
      replicas: 1
      port: 5001
      resources:
        requests: {cpu: \"$DOCLING_SERVE_CPU_REQUEST\", memory: \"$DOCLING_SERVE_MEM_REQUEST\"}
        limits: {cpu: \"$DOCLING_SERVE_CPU_LIMIT\", memory: \"$DOCLING_SERVE_MEM_LIMIT\"}
      storage:
        enabled: true
        size: \"$DOCLING_STORAGE_SIZE\"
        storageClassName: $STORAGE_CLASS
      config:
        extraEnv:
          - name: \"DOCLING_SERVE_ENABLE_REMOTE_SERVICES\"
            value: \"true\"
          - name: \"DOCLING_SERVE_ALLOW_CUSTOM_VLM_CONFIG\"
            value: \"true\"
    worker:
      image: ghcr.io/docling-project/docling-serve-cpu:v1.15.1
      replicas: 1
      resources:
        requests: {cpu: \"$DOCLING_WORKER_CPU_REQUEST\", memory: \"$DOCLING_WORKER_MEM_REQUEST\"}
        limits: {cpu: \"$DOCLING_WORKER_CPU_LIMIT\", memory: \"$DOCLING_WORKER_MEM_LIMIT\"}
      storage:
        enabled: true
        size: \"$DOCLING_STORAGE_SIZE\"
        storageClassName: $STORAGE_CLASS
    valkey:
      image: valkey/valkey:latest
      replicas: 1
      storage:
        enabled: true
        size: \"$VALKEY_STORAGE_SIZE\"
        storageClassName: $STORAGE_CLASS"
fi

cat <<EOF | oc apply -f -
apiVersion: openr.ag/v1alpha1
kind: OpenRAG
metadata:
  name: openrag
  namespace: $NAMESPACE
spec:
  targetNamespace: $NAMESPACE

  frontend:
    image: langflowai/openrag-frontend:latest
    resources:
      requests: {cpu: "$FRONTEND_CPU_REQUEST", memory: "$FRONTEND_MEM_REQUEST"}
      limits: {cpu: "$FRONTEND_CPU_LIMIT", memory: "$FRONTEND_MEM_LIMIT"}

  backend:
    image: langflowai/openrag-backend:latest
    jwtSigningKeySecret:
      name: openrag-jwt-signing-key
      key: JWT_SIGNING_KEY
    resources:
      requests: {cpu: "$BACKEND_CPU_REQUEST", memory: "$BACKEND_MEM_REQUEST"}
      limits: {cpu: "$BACKEND_CPU_LIMIT", memory: "$BACKEND_MEM_LIMIT"}
    storage:
      enabled: true
      size: "$BACKEND_STORAGE_SIZE"
      storageClassName: $STORAGE_CLASS
    env:
      - name: OPENAI_API_KEY
        valueFrom:
          secretKeyRef: {name: openrag-llm-credentials, key: OPENAI_API_KEY}
      - name: OPENSEARCH_NODE_COUNT_CHECK_ENABLED
        value: "false"
      - name: OPENRAG_OPENSEARCH_NUMBER_OF_SHARDS
        value: "1"
      - name: OPENRAG_OPENSEARCH_NUMBER_OF_REPLICAS
        value: "0"
      - name: OPENRAG_ENSURE_INDEX_REPLICAS_ON_STARTUP
        value: "false"
      - name: INGEST_SAMPLE_DATA
        value: "false"
$LANGFLOW_PUBLIC_URL_ENV

  langflow:
    image: langflowai/openrag-langflow:latest
    resources:
      requests: {cpu: "$LANGFLOW_CPU_REQUEST", memory: "$LANGFLOW_MEM_REQUEST"}
      limits: {cpu: "$LANGFLOW_CPU_LIMIT", memory: "$LANGFLOW_MEM_LIMIT"}
    storage:
      enabled: true
      size: "$LANGFLOW_STORAGE_SIZE"
      storageClassName: $STORAGE_CLASS
    command: ["python"]
    args: ["-m", "langflow", "run", "--host", "0.0.0.0", "--port", "7860", "--env-file", "/app/.env"]
    env:
      - name: OPENAI_API_KEY
        valueFrom:
          secretKeyRef: {name: openrag-llm-credentials, key: OPENAI_API_KEY}
      - name: LANGFLOW_DATABASE_URL
        valueFrom:
          secretKeyRef: {name: openrag-langflow-db, key: LANGFLOW_DATABASE_URL}
      - name: LANGFLOW_WORKERS
        value: "1"

  llm:
    provider: openai
    model: $LLM_MODEL

  embedding:
    provider: openai
    model: $EMBEDDING_MODEL

  opensearch:
    host: openrag-opensearch.$NAMESPACE.svc.cluster.local
    port: 9200
    scheme: https
    indexName: documents
    credentialsSecret: openrag-opensearch-credentials
$DOCLING_BLOCK

  networkPolicy:
    enabled: false
EOF

# ---------------------------------------------------------------------------
# Wait for the app pods
# ---------------------------------------------------------------------------
log "Waiting for frontend/backend/langflow to become ready (this can take a few minutes)..."
for dep in openrag-fe openrag-be openrag-lf; do
  oc rollout status deployment/"$dep" -n "$NAMESPACE" --timeout=420s || warn "$dep did not become ready within the timeout -- check 'oc get pods -n $NAMESPACE'"
done

# ---------------------------------------------------------------------------
# Docling: fix the Deployment strategy to Recreate (the operator defaults to
# RollingUpdate, which deadlocks against RWO storage on any spec change --
# see notes doc §3.9). Harmless on first install; matters on any future
# re-run that changes docling resources/image.
# ---------------------------------------------------------------------------
if [ "$ENABLE_DOCLING" = "true" ]; then
  log "Waiting for Docling components and patching their update strategy to Recreate..."
  for dep in docling-serve docling-worker; do
    for _ in $(seq 1 30); do
      oc get deployment "$dep" -n "$NAMESPACE" >/dev/null 2>&1 && break
      sleep 5
    done
    if oc get deployment "$dep" -n "$NAMESPACE" >/dev/null 2>&1; then
      oc patch deployment "$dep" -n "$NAMESPACE" --type=merge \
        -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' >/dev/null
      oc rollout status deployment/"$dep" -n "$NAMESPACE" --timeout=420s || warn "$dep did not become ready within the timeout"
    else
      warn "$dep never appeared -- check the operator logs."
    fi
  done
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
log "Done."
if [ -n "$FRONTEND_HOST" ]; then
  echo "  Frontend: https://$FRONTEND_HOST"
fi
if [ -n "$LANGFLOW_HOST" ]; then
  echo "  Langflow: https://$LANGFLOW_HOST"
fi
echo
echo "Known limitation: image/flow version skew"
echo "  The langflowai/openrag-* images are pulled at :latest, not pinned to"
echo "  OPENRAG_REPO_REF. If a future :latest image's bundled custom_components"
echo "  drift out of sync with its own bundled flows, chat may fail with"
echo "  'Flow build blocked: custom components are not allowed'. This installer"
echo "  deliberately never sets flowsRef so Langflow always uses whatever flows"
echo "  ship inside the image itself (guaranteed to match) -- if you still hit"
echo "  this, it means the image itself is internally inconsistent, not a"
echo "  version-skew issue this installer can prevent."
