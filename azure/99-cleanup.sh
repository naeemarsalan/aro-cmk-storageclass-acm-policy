#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh
oc delete managedcluster "$CLUSTER" --ignore-not-found
az aro delete -g "$RG" -n "$CLUSTER" -y
az group delete -n "$RG" -y   # Key Vault stays soft-deleted (purge protection)
