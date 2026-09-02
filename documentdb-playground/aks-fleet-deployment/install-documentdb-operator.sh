#!/usr/bin/env bash
set -euo pipefail

# Install the DocumentDB operator independently on every member cluster.
# Operator namespaces contain cluster-local certificates, webhook CAs, Secrets,
# and CertificateRequests and must not be propagated with Fleet.

RESOURCE_GROUP="${RESOURCE_GROUP:-documentdb-aks-fleet-rg}"
HUB_REGION="${HUB_REGION:-westus3}"
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/operator/documentdb-helm-chart"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-200}"
VALUES_FILE="${VALUES_FILE:-}"
BUILD_CHART="${BUILD_CHART:-true}"

# Make sure we have the basics
for cmd in az kubectl helm jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found. Install it and re-run." >&2
    exit 1
  fi
done

# Get every member cluster context.
MEMBERS=$(az aks list -g "$RESOURCE_GROUP" -o json | jq -r '.[] | select(.name|startswith("member-")) | .name')
for cluster in $MEMBERS; do
  echo "Fetching creds for $cluster..."
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$cluster" --overwrite-existing
  if [[ "$cluster" == *"$HUB_REGION"* ]]; then HUB_CLUSTER="$cluster"; fi
done

# Build/package the chart once, or select the published chart.
if [ "$BUILD_CHART" == true ]; then
  CHART_PKG="$SCRIPT_DIR/documentdb-operator-0.0.${VERSION}.tgz"
  if [ -f "$CHART_PKG" ]; then
    echo "Found existing chart package $CHART_PKG"
    rm -f "$CHART_PKG"
  fi
  echo "Packaging chart (helm dependency update && helm package)..."
  helm dependency update "$CHART_DIR"
  helm package "$CHART_DIR" --version 0.0."${VERSION}" --destination "$SCRIPT_DIR"
  CHART_REF="$CHART_PKG"
else
  echo "Set CHART_VERSION to pin a specific release (e.g. CHART_VERSION=0.2.0); see https://github.com/documentdb/documentdb-kubernetes-operator/releases for available versions."
  if [ -z "${CHART_VERSION:-}" ]; then
    echo "Error: CHART_VERSION is required when installing from the OCI registry. Re-run with CHART_VERSION=<x.y.z> set." >&2
    exit 1
  fi
  CHART_REF="oci://ghcr.io/documentdb/documentdb-operator"
fi

install_operator() {
  local cluster="$1"
  local args=(
    upgrade --install documentdb-operator "$CHART_REF"
    --namespace documentdb-operator
    --kube-context "$cluster"
    --create-namespace
    --wait
    --timeout 10m
  )

  if [ "$BUILD_CHART" != true ]; then
    args+=(--version "$CHART_VERSION")
  fi
  if [ -n "$VALUES_FILE" ] && [ -f "$VALUES_FILE" ]; then
    args+=(--values "$VALUES_FILE")
  fi

  helm "${args[@]}"
}

wait_for_cnpg_webhook_ca() {
  local cluster="$1"
  local timeout_seconds="${2:-180}"
  local end_time=$((SECONDS + timeout_seconds))
  local ca_bundle

  echo "Waiting for CNPG webhooks on $cluster to trust their local serving certificate..."
  while [ "$SECONDS" -lt "$end_time" ]; do
    ca_bundle=$(kubectl --context "$cluster" get secret cnpg-ca-secret \
      -n cnpg-system -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)

    if [ -n "$ca_bundle" ] && \
      kubectl --context "$cluster" get mutatingwebhookconfiguration \
        cnpg-mutating-webhook-configuration -o json 2>/dev/null | \
        jq -e --arg ca "$ca_bundle" 'all(.webhooks[]; .clientConfig.caBundle == $ca)' >/dev/null && \
      kubectl --context "$cluster" get validatingwebhookconfiguration \
        cnpg-validating-webhook-configuration -o json 2>/dev/null | \
        jq -e --arg ca "$ca_bundle" 'all(.webhooks[]; .clientConfig.caBundle == $ca)' >/dev/null; then
      echo "CNPG webhook CA bundles are consistent on $cluster."
      return 0
    fi

    sleep 5
  done

  echo "Error: CNPG webhook CA bundles on $cluster do not match cnpg-ca-secret." >&2
  echo "Check for a legacy Fleet AppliedWork owning the CNPG webhook configurations." >&2
  return 1
}

for cluster in $MEMBERS; do
  echo ""
  echo "Installing DocumentDB operator on $cluster..."
  kubectl --context "$cluster" wait --for=condition=Available \
    deployment/cert-manager-webhook -n cert-manager --timeout=240s
  install_operator "$cluster"

  kubectl --context "$cluster" wait --for=condition=Ready \
    issuer/selfsigned-issuer -n cnpg-system --timeout=120s
  kubectl --context "$cluster" wait --for=condition=Ready \
    certificate/sidecarinjector-client -n cnpg-system --timeout=180s
  kubectl --context "$cluster" wait --for=condition=Ready \
    certificate/sidecarinjector-server -n cnpg-system --timeout=180s
  kubectl --context "$cluster" rollout status \
    deployment/sidecar-injector -n cnpg-system --timeout=240s
  wait_for_cnpg_webhook_ca "$cluster"
done

# Show status on all member clusters
echo "Checking operator status on all member clusters..."

for CLUSTER in $MEMBERS; do
  echo ""
  echo "======================================="
  echo "Cluster: $CLUSTER"
  echo "======================================="

  # Get the context name for this cluster
  CONTEXT="$CLUSTER"

  echo "Checking rollout status on $CLUSTER..."
  set +e
  kubectl --context "$CONTEXT" -n documentdb-operator rollout status deployment/documentdb-operator --timeout=300s
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "Warning: operator rollout didn't complete within timeout on $CLUSTER. Check pods:"
    kubectl --context "$CLUSTER" get pods -n documentdb-operator 2>/dev/null || echo "  Unable to get pods on $CLUSTER"
  else
    echo "✓ Operator rollout completed successfully on $CLUSTER"
  fi
  echo ""

  echo "Operator deployments in $CLUSTER:"
  kubectl --context "$CONTEXT" get deploy -n documentdb-operator -o wide 2>/dev/null || echo "  No deployments found or unable to connect"

  echo ""
  echo "Operator pods in $CLUSTER:"
  kubectl --context "$CONTEXT" get pods -n documentdb-operator -o wide 2>/dev/null || echo "  No pods found or unable to connect"

  echo ""
  echo "cnpg-system pods in $CLUSTER:"
  kubectl --context "$CONTEXT" get pods -n cnpg-system -o wide 2>/dev/null || echo "  No pods found or unable to connect"
done

echo ""
echo "======================================="
echo "Summary of operator status across all member clusters"
echo "======================================="

# Show a summary table
echo ""
echo "Deployment Status Summary:"
for CLUSTER in $MEMBERS; do
  READY=$(kubectl --context "$CLUSTER" get deploy documentdb-operator -n documentdb-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl --context "$CLUSTER" get deploy documentdb-operator -n documentdb-operator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  echo "  $CLUSTER: $READY/$DESIRED replicas ready"
done

echo ""
echo "Done. If any commands failed due to permissions, ensure your Azure account has contributor/AKS admin permissions in resource group '$RESOURCE_GROUP'."
