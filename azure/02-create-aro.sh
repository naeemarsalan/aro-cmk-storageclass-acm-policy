#!/usr/bin/env bash
# ARO cluster whose node OS disks use the DES. The ACM policy later discovers
# the same DES from the Machine objects and reuses it for PVs.
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh
PULL_SECRET=${PULL_SECRET:-}   # path to Red Hat pull secret (optional)
# Optional pre-created cluster service principal; otherwise az aro creates one.
CLIENT_ID=${CLIENT_ID:-}; CLIENT_SECRET=${CLIENT_SECRET:-}

DES_ID=$(az disk-encryption-set show -n "$DES" -g "$RG" --query id -o tsv)

az network vnet create -g "$RG" -n "$VNET" --address-prefixes 10.0.0.0/22 -o none
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n master --address-prefixes 10.0.0.0/23 -o none
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n worker --address-prefixes 10.0.2.0/23 -o none

# The ARO resource provider needs to read the DES to build the nodes.
# f1dd0a37-... is the well-known appId of the "Azure Red Hat OpenShift RP" SP.
ARO_RP=$(az ad sp show --id f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875 --query id -o tsv)
az role assignment create --assignee-object-id "$ARO_RP" --assignee-principal-type ServicePrincipal \
  --role Reader --scope "$DES_ID" -o none

az aro create -g "$RG" -n "$CLUSTER" --vnet "$VNET" \
  --master-subnet master --worker-subnet worker \
  --disk-encryption-set "$DES_ID" \
  --master-vm-size "${MASTER_VM_SIZE:-Standard_D8s_v5}" --worker-vm-size "${WORKER_VM_SIZE:-Standard_D4s_v5}" \
  ${CLIENT_ID:+--client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET"} \
  ${PULL_SECRET:+--pull-secret @"$PULL_SECRET"}

# The cluster service principal (used by the Azure Disk CSI driver) must be
# able to read the DES when provisioning PVs.
CLUSTER_SP_APPID=$(az aro show -g "$RG" -n "$CLUSTER" --query servicePrincipalProfile.clientId -o tsv)
CLUSTER_SP=$(az ad sp show --id "$CLUSTER_SP_APPID" --query id -o tsv)
az role assignment create --assignee-object-id "$CLUSTER_SP" --assignee-principal-type ServicePrincipal \
  --role Reader --scope "$DES_ID" -o none
