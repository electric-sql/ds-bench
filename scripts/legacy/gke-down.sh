#!/usr/bin/env bash
# Tear down the dedicated Phase-2b GKE cluster to stop billing.
# The Artifact Registry repo is kept (cheap, holds the pushed images);
# delete it manually if you want a fully clean slate.
set -euo pipefail
PROJECT="${1:-$(gcloud config get-value project)}"
gcloud container clusters delete ds-bench --zone europe-west1-b --project "$PROJECT" --quiet
echo "deleted cluster ds-bench (Artifact Registry repo kept; delete manually if desired)"
