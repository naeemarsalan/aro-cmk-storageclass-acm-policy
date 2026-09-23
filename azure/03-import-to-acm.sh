#!/usr/bin/env bash
# Import the ARO cluster into ACM with the labels the Placement selects on.
# Run with KUBECONFIG pointing at the ACM hub.
# (cloud=Azure is added automatically by ACM once the klusterlet reports in.)
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh

API=$(az aro show -g "$RG" -n "$CLUSTER" --query apiserverProfile.url -o tsv)
PASS=$(az aro list-credentials -g "$RG" -n "$CLUSTER" --query kubeadminPassword -o tsv)

TMPKC=$(mktemp); trap 'rm -f "$TMPKC"' EXIT
KUBECONFIG="$TMPKC" oc login "$API" -u kubeadmin -p "$PASS" --insecure-skip-tls-verify=true >/dev/null
TOKEN=$(KUBECONFIG="$TMPKC" oc whoami -t)

oc apply -f - <<YAML
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${CLUSTER}
  labels:
    environment: ${ACM_ENV_LABEL}
    cloud: Azure
    vendor: OpenShift
spec:
  hubAcceptsClient: true
YAML

# The hub creates the cluster namespace asynchronously.
until oc get ns "$CLUSTER" >/dev/null 2>&1; do sleep 2; done

oc create secret generic auto-import-secret -n "$CLUSTER" \
  --from-literal=autoImportRetry=5 --from-literal=server="$API" --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${CLUSTER}
  namespace: ${CLUSTER}
spec:
  applicationManager: {enabled: true}
  certPolicyController: {enabled: true}
  policyController: {enabled: true}
  searchCollector: {enabled: true}
YAML
