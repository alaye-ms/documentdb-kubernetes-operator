# AKS Fleet Deployment

This directory contains templates for deploying an AKS Fleet with a hub cluster and three member clusters across different Azure regions.

## Architecture

- **Fleet Hub**: Deployed in East US
- **Member Clusters**: Deployed in West US, Central US, and South Central US
- **Cluster Size**: Uses smallest SKU (Standard_B2s) with 1 node for cost optimization
- **Kubernetes Version**: 1.28.9 (configurable)

## Deployment

### Using Bicep (Recommended)

```bash
./deploy-fleet-bicep.sh
```

## Prerequisites

- Azure CLI installed and logged in
- Sufficient quota in target regions for AKS clusters
- Contributor access to the subscription

## Configuration

Edit `parameters.bicepparam` to customize:
- Cluster names
- Regions
- VM sizes
- Node counts
- Kubernetes version

## Post-Deployment

After deployment, get credentials for clusters:

```bash
# Hub cluster
az aks get-credentials --resource-group documentdb-aks-fleet-rg --name aks-fleet-hub

# List all clusters
kubectl get clusters --all-namespaces
```

## Clean Up

To delete all resources:

```bash
az group delete --name documentdb-aks-fleet-rg --yes --no-wait
```
