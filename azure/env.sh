# Edit to taste, then: source azure/env.sh
export LOCATION=${LOCATION:-eastus}          # needs availability zones for Premium_ZRS
export CLUSTER=${CLUSTER:-aro-cmk-lab}
export RG=${RG:-${CLUSTER}-rg}
export KV=${KV:-${CLUSTER}-kv-$(az account show --query id -o tsv | cut -c1-5)}  # globally unique, <=24 chars
export KEY=${KEY:-aro-cmk-key}
export DES=${DES:-${CLUSTER}-des}
export VNET=${VNET:-${CLUSTER}-vnet}
export ACM_ENV_LABEL=${ACM_ENV_LABEL:-lab}   # matches the Placement
