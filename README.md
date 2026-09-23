# OpenRAG OpenShift installer

A repeatable, from-scratch installer for [IBM OpenRAG](https://github.com/langflow-ai/openrag) on
OpenShift, using the operator installation path. Every workaround discovered during a live
deployment (see `kubernetes/OPENSHIFT_DEPLOYMENT_NOTES.md` in
[langflow-ai/openrag#2412](https://github.com/langflow-ai/openrag/pull/2412)) is baked in from the
start instead of being rediscovered live.

## What it deploys

- The OpenRAG operator (Helm) + CRD, with its RBAC chart-drift bug patched
- PostgreSQL (OpenShift's built-in `postgresql` image stream) — for Langflow
- OpenSearch (`langflowai/openrag-opensearch`, the only image with the `jvector` k-NN engine
  the backend requires) — with the arbitrary-UID/SCC fix applied from the start
- The `OpenRAG` CR: frontend, backend, Langflow, and optionally Docling (serve + worker) + Valkey
- OpenShift Routes for the frontend and Langflow, with `LANGFLOW_PUBLIC_URL` wired up correctly

## Prerequisites

- `oc`, `helm`, `git`, `openssl`, `python3` on your PATH
- Logged into the target cluster: `oc login ...`
- An OpenAI API key
- Cluster-admin access is **not** strictly required, but this script does two cluster-scoped
  things that do need elevated privileges: installing the CRD, and granting the `anyuid` SCC to a
  dedicated ServiceAccount for OpenSearch (needed because the `langflowai/openrag-opensearch`
  image's security-bootstrap script requires running as UID 1000 specifically — see the notes doc
  for why). If you don't have that access, get someone who does to run just those two steps, or
  request the SCC grant be pre-approved for the `openrag-opensearch` SA in your target namespace.

## Usage

```bash
oc login --token=... --server=...
cp .env.example .env
$EDITOR .env          # at minimum, set OPENAI_API_KEY
./install.sh
```

Re-running `install.sh` is safe — it's idempotent: existing secrets, the namespace, the CRD, and
the operator installation are all left alone if already present (this matters most for the JWT
signing key, which the operator refuses to let you change after the fact).

To tear everything down:

```bash
./uninstall.sh
```

## Configuration

All configuration lives in `.env` (copy `.env.example` to start) — see that file for every
available option (storage sizes, resource requests/limits, model names, which components to
enable). `.env` is gitignored; nothing sensitive gets committed.

## Known limitation: image/flow version skew

The `langflowai/openrag-*` container images are pulled at the `:latest` tag, not pinned to
`OPENRAG_REPO_REF` (which only controls which commit's CRD/Helm chart *source* gets used — Kubernetes
manifests, not container images). This installer deliberately never sets Langflow's `flowsRef`
field, so Langflow always loads the flows bundled *inside* the image itself, which are guaranteed
to match that image's bundled custom components. If a published `:latest` image ever ships
internally inconsistent flows/components (i.e., a real upstream bug, not a version-skew issue this
installer causes), chat may still fail with `Flow build blocked: custom components are not
allowed` — check `kubernetes/OPENSHIFT_DEPLOYMENT_NOTES.md` §3.13 for the full diagnosis if that
happens.

## Why a separate repo instead of a PR to langflow-ai/openrag

This installer encodes personal/environment-specific choices (a working single-node OpenSearch
setup, specific resource sizes tuned for one cluster, etc.) rather than being a general-purpose
fix — those went back upstream separately as
[langflow-ai/openrag#2412](https://github.com/langflow-ai/openrag/pull/2412), a write-up of the
underlying issues with recommendations for the maintainers to fix at the source (image, operator,
and chart level). This repo is the pragmatic "get a working install today, on any cluster" tool
that sits on top of that, until those upstream fixes land.
