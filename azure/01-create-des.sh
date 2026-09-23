#!/usr/bin/env bash
# Key Vault + key + Disk Encryption Set (double encryption: platform + CMK).
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh

az group create -n "$RG" -l "$LOCATION" -o none

az keyvault create -n "$KV" -g "$RG" -l "$LOCATION" \
  --enable-purge-protection true --enable-rbac-authorization true -o none
KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)

# Let whoever is signed in (user or service principal) create keys in the vault.
if [[ $(az account show --query user.type -o tsv) == servicePrincipal ]]; then
  ME=$(az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv); ME_TYPE=ServicePrincipal
else
  ME=$(az ad signed-in-user show --query id -o tsv); ME_TYPE=User
fi
az role assignment create --assignee-object-id "$ME" --assignee-principal-type "$ME_TYPE" \
  --role "Key Vault Crypto Officer" --scope "$KV_ID" -o none
echo "waiting for RBAC propagation..."; sleep 60

az keyvault key create --vault-name "$KV" -n "$KEY" --protection software -o none
KEY_URL=$(az keyvault key show --vault-name "$KV" -n "$KEY" --query key.kid -o tsv)

# Encryption type must match the StorageClass diskEncryptionType.
az disk-encryption-set create -n "$DES" -g "$RG" -l "$LOCATION" \
  --source-vault "$KV_ID" --key-url "$KEY_URL" \
  --encryption-type EncryptionAtRestWithPlatformAndCustomerKeys -o none
DES_ID=$(az disk-encryption-set show -n "$DES" -g "$RG" --query id -o tsv)
DES_MI=$(az disk-encryption-set show -n "$DES" -g "$RG" --query identity.principalId -o tsv)

# DES managed identity -> wrap/unwrap with the key.
az role assignment create --assignee-object-id "$DES_MI" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Crypto Service Encryption User" --scope "$KV_ID" -o none

echo "DES_ID=$DES_ID"
