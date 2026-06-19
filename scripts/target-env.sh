#!/usr/bin/env bash
# Sourced by the benchmark runners + cluster/build helpers to select where the
# benchmark runs: a LOCAL kind cluster (fast dev loop, no cloud, no billing) or a
# REMOTE GKE cluster (measurement-grade, multi-node isolation).
#
#   DS_TARGET=local   (default) -> kind cluster `kind-<KIND_CLUSTER>`, locally
#                                  built images loaded via `kind load`, single
#                                  node (no role pools), IfNotPresent pulls.
#   DS_TARGET=remote            -> GKE context, Artifact Registry images, role
#                                  node pools, Always pulls.
#
# It exports the values the manifests need; the runners envsubst these into
# gke/*.yaml (image refs, pull policy, node selectors) and use $KCTX for kubectl.
# This file only sets variables — it never touches a cluster.

DS_TARGET="${DS_TARGET:-local}"

case "$DS_TARGET" in
  local)
    KIND_CLUSTER="${KIND_CLUSTER:-ds-bench}"
    KCTX="kind-${KIND_CLUSTER}"
    # Images are built locally (native arch) and `kind load`ed — no registry.
    IMG_SERVER="durable-streams:dev"
    IMG_DSBENCH="ds-bench:dev"
    IMG_METRICS="ds-bench:dev"        # ds-bench:dev carries bash+curl+procps for the sidecar
    PULL_POLICY="IfNotPresent"        # use the kind-loaded image; never reach for a registry
    NODESEL_SERVER="{}"               # single-node kind: schedule anywhere
    NODESEL_CLIENT="{}"
    ;;
  remote)
    PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
    ZONE="${ZONE:-europe-west1-b}"
    CLUSTER="${CLUSTER:-ds-bench}"
    KCTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
    REG="europe-west1-docker.pkg.dev/${PROJECT}/ds-bench"
    IMG_SERVER="${REG}/durable-streams:dev"
    IMG_DSBENCH="${REG}/ds-bench:dev"
    IMG_METRICS="${REG}/micro:dev"
    PULL_POLICY="Always"
    NODESEL_SERVER='{ "role": "server" }'
    NODESEL_CLIENT='{ "role": "client" }'
    ;;
  *)
    echo "DS_TARGET must be 'local' or 'remote' (got: '$DS_TARGET')" >&2
    return 2 2>/dev/null || exit 2
    ;;
esac

# Server-side fsync group-commit window (µs). 0 = no batching (default, identical
# to the un-patched server). Requires a server image built with the group-commit
# patch. Substituted into gke/durable-streams.yaml.
GROUP_COMMIT_WINDOW_US="${GROUP_COMMIT_WINDOW_US:-0}"
# Server pod memory limit (the cgroup OOM ceiling — drives fan-out subscriber capacity).
SERVER_MEM="${SERVER_MEM:-16Gi}"

# Vars referenced by envsubst in the manifests + by the runners.
export DS_TARGET KCTX IMG_SERVER IMG_DSBENCH IMG_METRICS PULL_POLICY \
       NODESEL_SERVER NODESEL_CLIENT PROJECT ZONE CLUSTER KIND_CLUSTER REG \
       GROUP_COMMIT_WINDOW_US SERVER_MEM

# Every manifest envsubst must whitelist these so the image/policy/selector
# placeholders resolve. Runners reference $MANIFEST_VARS in their envsubst calls.
MANIFEST_VARS='${IMG_SERVER} ${IMG_DSBENCH} ${IMG_METRICS} ${PULL_POLICY} ${NODESEL_SERVER} ${NODESEL_CLIENT} ${GROUP_COMMIT_WINDOW_US} ${SERVER_MEM}'
export MANIFEST_VARS
