# ARO CMK StorageClass via ACM Policy

One ACM policy that, as soon as an ARO cluster is imported into ACM:

1. Creates `managed-csi-encrypted-cmk`, the **default** StorageClass, with
   `diskEncryptionType: EncryptionAtRestWithPlatformAndCustomerKeys` and
   `diskEncryptionSetID` filled in automatically.
2. Removes the stock `managed-csi` StorageClass (`ClusterCSIDriver`
   `storageClassState: Removed`), so the CMK class is the only Azure Disk class.

## The DES ID is discovered per cluster

Every ARO cluster has its own Disk Encryption Set (different subscription/RG),
so it can't be hard-coded in the policy. Instead a **managed-cluster template**
looks up each cluster's own Machine objects and reads the DES that ARO used for
the node OS disks (`az aro create --disk-encryption-set ...`):

```gotemplate
{{- range (lookup "machine.openshift.io/v1beta1" "Machine" "openshift-machine-api" "").items }}
  {{- $des = dig "spec" "providerSpec" "value" "osDisk" "managedDisk" "diskEncryptionSet" "id" "" . }}
{{- end }}
diskEncryptionSetID: '{{ $des }}'
```

The same policy therefore works for 1 or 1,000 clusters with no per-cluster
config. If no DES is found, the template calls `fail` and the policy reports
**NonCompliant** with a clear message rather than creating a broken StorageClass.

## What ARO does on its own vs. what the policy adds

When ARO is created with `--disk-encryption-set`, the ARO installer already
creates `managed-csi-encrypted-cmk` (default) and un-defaults `managed-csi` —
once, at install time (no operator reconciles it). But that class is:

| | ARO install-time | After this policy |
|---|---|---|
| `diskEncryptionSetID` | cluster DES | cluster DES (discovered) |
| `diskEncryptionType` | *(unset → CMK only)* | `EncryptionAtRestWithPlatformAndCustomerKeys` |
| `storageaccounttype` | `Premium_LRS` | `Premium_ZRS` |
| `managed-csi` | present, non-default | removed |

Because StorageClass parameters are immutable, the policy uses
`recreateOption: IfRequired` to replace ARO's class with the desired one.

## Tested

ARO 4.18.34 (eastus), ACM 2.15.7 hub:

- Import → policy Compliant in ~1 min; `managed-csi-encrypted-cmk` recreated
  with the discovered DES, `managed-csi` removed and not recreated.
- Test PVC bound; the Azure disk reports `Premium_ZRS`,
  `EncryptionAtRestWithPlatformAndCustomerKeys`, and the cluster DES.
- Only Reader on the DES was needed for the cluster SP (`az aro create` adds
  the RP/SP role assignments on the DES itself during validation).

## Layout

```
hub/                         acm-config namespace + ManagedClusterSetBinding
policygenerator/             PolicyGenerator source (GitOps / kustomize)
  policy-generator-config.yaml
  placement.yaml             environment=lab, cloud=Azure, no aro_cmk_sc_override label
  manifests/
    cmk-storageclass.yaml    templated StorageClass (DES lookup)
    disable-default-csi-sc.yaml
rendered/policy.yaml         kustomize output, for a plain `oc apply`
azure/                       scripts to build a test DES + ARO cluster and import it
```

## Use it

```bash
oc apply -k hub/
oc apply -f rendered/policy.yaml          # or point Argo CD at policygenerator/
```

Regenerate `rendered/` after edits:

```bash
kustomize build --enable-alpha-plugins policygenerator > rendered/policy.yaml
```

### Cluster lifecycle

- **Day 0:** create ARO with `--disk-encryption-set` (`azure/01-create-des.sh`,
  `azure/02-create-aro.sh`).
- **Import:** the `ManagedCluster` gets `environment=lab` at import time
  (`azure/03-import-to-acm.sh`); ACM adds `cloud=Azure` itself.
- **First policy evaluation:** the policy creates the CMK class and removes
  `managed-csi` before any workloads request PVCs.
- **Opt out a cluster:** label it `aro_cmk_sc_override=true`.

## Azure prerequisites

| Who | Role | Scope | Why |
|---|---|---|---|
| DES managed identity | Key Vault Crypto Service Encryption User | Key Vault | wrap/unwrap with the CMK |
| ARO RP (`Azure Red Hat OpenShift RP`) | Reader | DES | build nodes with encrypted OS disks |
| Cluster service principal | Reader | DES | Azure Disk CSI provisions PVs with the DES |

The DES must be created with `--encryption-type EncryptionAtRestWithPlatformAndCustomerKeys`
to match the StorageClass. `Premium_ZRS` needs a region with availability zones.

## Notes

- StorageClass parameters are immutable; `recreateOption: IfRequired` lets the
  policy delete and recreate the class if the DES ever changes. Existing PVs are
  not affected.
- `storageClassState: Removed` requires OpenShift 4.13 or later.
