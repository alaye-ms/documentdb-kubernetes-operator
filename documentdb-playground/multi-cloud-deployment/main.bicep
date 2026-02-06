targetScope = 'resourceGroup'

@description('Name of the Fleet Hub AKS cluster')
param hubClusterName string = 'aks-fleet-hub'

@description('Location for the Fleet Hub')
param hubRegion string = 'eastus2'

@description('Name for member cluster')
param memberName string = 'aks-fleet-member'

@description('Location for member cluster')
param memberRegion string = 'eastus2'

@description('Kubernetes version. Leave empty to use the region default GA version.')
param kubernetesVersion string = ''

@description('Name for the second member cluster')
param member2Name string = 'aks-fleet-member-2'

@description('Location for the second member cluster')
param member2Region string = 'westus2'

@description('VM size for cluster nodes')
param hubVmSize string = 'Standard_DS3_v2'

@description('Number of nodes per cluster')
param nodeCount int = 1

var fleetName = '${hubClusterName}-fleet'

// Optionally include kubernetesVersion in cluster properties
var maybeK8sVersion = empty(kubernetesVersion) ? {} : { kubernetesVersion: kubernetesVersion }

// Fleet resource
resource fleet 'Microsoft.ContainerService/fleets@2025-03-01' = {
  name: fleetName
  location: hubRegion
  properties: {
    hubProfile: {
      dnsPrefix: fleetName
    }
  }
}

// Member AKS Cluster 1 (using default Azure CNI without custom VNets)
resource memberCluster 'Microsoft.ContainerService/managedClusters@2023-10-01' = {
  name: memberName
  location: memberRegion
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    dnsPrefix: 'member-${memberRegion}-dns'
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
        vmSize: hubVmSize
        mode: 'System'
        osType: 'Linux'
      }
    ]
  }, maybeK8sVersion)
}

// Member AKS Cluster 2 (using default Azure CNI without custom VNets)
resource member2Cluster 'Microsoft.ContainerService/managedClusters@2023-10-01' = {
  name: member2Name
  location: member2Region
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    dnsPrefix: 'member-${member2Region}-dns'
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
        vmSize: hubVmSize
        mode: 'System'
        osType: 'Linux'
      }
    ]
  }, maybeK8sVersion)
}

// Member cluster 1 fleet membership
resource memberFleetMembers 'Microsoft.ContainerService/fleets/members@2023-10-15' = {
  name: 'member-${memberRegion}-${uniqueString(resourceGroup().id, memberRegion)}'
  parent: fleet
  properties: {
    clusterResourceId: memberCluster.id
  }
}

// Member cluster 2 fleet membership
resource member2FleetMembers 'Microsoft.ContainerService/fleets/members@2023-10-15' = {
  name: 'member-${member2Region}-${uniqueString(resourceGroup().id, member2Region)}'
  parent: fleet
  properties: {
    clusterResourceId: member2Cluster.id
  }
}

// Outputs
output fleetId string = fleet.id
output fleetName string = fleet.name
output memberClusterId string = memberCluster.id
output memberClusterName string = memberCluster.name
output member2ClusterId string = member2Cluster.id
output member2ClusterName string = member2Cluster.name
