#!/bin/bash
# Install cert-manager independently on all member clusters in the fleet.
# Certificate controllers and their generated runtime resources must remain
# cluster-local; propagating the namespace with Fleet causes ownership conflicts.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-documentdb-aks-fleet-rg}"
MEMBERS=$(az aks list -g "$RESOURCE_GROUP" -o json | jq -r '.[] | select(.name|startswith("member-")) | .name')

echo -e "Members:\n$MEMBERS"

# Ensure all member contexts are available.
for cluster in $MEMBERS; do
  echo "Fetching creds for $cluster..."
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$cluster" --overwrite-existing
done

for cluster in $MEMBERS; do
  if kubectl --context "$cluster" get clusterresourceplacement cert-manager-crp >/dev/null 2>&1; then
    echo "Error: legacy cert-manager-crp exists on $cluster." >&2
    echo "Migrate or remove that placement before using per-cluster Helm installs; mixed ownership is unsafe." >&2
    exit 1
  fi
done

helm repo add jetstack https://charts.jetstack.io 
helm repo update 

for cluster in $MEMBERS; do
  echo -e "\nInstalling cert-manager on $cluster..."
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --kube-context "$cluster" \
    --wait \
    --timeout 5m

  for crd in \
    certificates.cert-manager.io \
    certificaterequests.cert-manager.io \
    clusterissuers.cert-manager.io \
    issuers.cert-manager.io; do
    kubectl --context "$cluster" wait --for=condition=Established \
      "crd/$crd" --timeout=240s
  done

  for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
    kubectl --context "$cluster" rollout status \
      "deployment/$deployment" -n cert-manager --timeout=240s
  done
done

echo -e "\nDone. cert-manager is running independently on every member cluster."
