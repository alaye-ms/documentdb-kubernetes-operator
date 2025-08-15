targetScope = 'resourceGroup'

@description('Name of the Fleet Hub AKS cluster')
param hubClusterName string = 'aks-fleet-hub'

@description('Location for the Fleet Hub')
param hubRegion string = 'eastus2'

@description('Locations for member clusters')
param memberRegions array = [
  'westus3'
  'uksouth'
  'eastus2'
]

@description('Kubernetes version. Leave empty to use the region default GA version.')
param kubernetesVersion string = ''

@description('VM size for the hub cluster nodes')
param hubVmSize string = 'Standard_D2ps_v6'


@description('Number of nodes per cluster')
param nodeCount int = 1

var fleetName = '${hubClusterName}-fleet'

// Optionally include kubernetesVersion in cluster properties
var maybeK8sVersion = empty(kubernetesVersion) ? {} : { kubernetesVersion: kubernetesVersion }

// Member clusters will use the same SKU across the board

// Fleet resource
resource fleet 'Microsoft.ContainerService/fleets@2023-10-15' = {
  name: fleetName
  location: hubRegion
  properties: {}
}

// Hub AKS Cluster
resource hubCluster 'Microsoft.ContainerService/managedClusters@2023-10-01' = {
  name: hubClusterName
  location: hubRegion
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    dnsPrefix: '${hubClusterName}-dns'
  agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
    vmSize: hubVmSize
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
  }, maybeK8sVersion)
}

// Hub cluster fleet membership
resource hubFleetMember 'Microsoft.ContainerService/fleets/members@2023-10-15' = {
  name: '${hubClusterName}-member'
  parent: fleet
  properties: {
    clusterResourceId: hubCluster.id
  }
}

// Member AKS Clusters
resource memberClusters 'Microsoft.ContainerService/managedClusters@2023-10-01' = [for (region, i) in memberRegions: {
  name: 'member-${region}-${uniqueString(resourceGroup().id, region, string(i))}'
  location: region
  identity: {
    type: 'SystemAssigned'
  }
  properties: union({
    dnsPrefix: 'member-${region}-dns'
  agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
  vmSize: hubVmSize
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
    }
  }, maybeK8sVersion)
}]

// Member clusters fleet membership
resource memberFleetMembers 'Microsoft.ContainerService/fleets/members@2023-10-15' = [for (region, i) in memberRegions: {
  name: 'member-${region}-${uniqueString(resourceGroup().id, region, string(i))}'
  parent: fleet
  properties: {
    clusterResourceId: memberClusters[i].id
  }
}]

// Outputs
output fleetId string = fleet.id
output fleetName string = fleet.name
output hubClusterId string = hubCluster.id
output hubClusterName string = hubCluster.name
output memberClusterIds array = [for (region, i) in memberRegions: memberClusters[i].id]
output memberClusterNames array = [for (region, i) in memberRegions: memberClusters[i].name]
