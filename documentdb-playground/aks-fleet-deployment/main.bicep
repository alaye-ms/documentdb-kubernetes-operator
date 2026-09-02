targetScope = 'resourceGroup'

@description('Locations for member clusters')
param memberRegions array = [
  'westus3'
  'uksouth'
  'eastus2'
]

@description('Kubernetes version. Defaults to 1.35.0. Set to "" to use the region default GA version.')
param kubernetesVersion string = '1.35.0'

@description('VM size for the cluster nodes')
param vmSize string = 'standard_d2ads_v7'

@description('Number of nodes per cluster')
param nodeCount int = 2

@description('Tag all AKS public load balancer IPs with FirstPartyUsage=/Unprivileged')
param tagAllLoadBalancers bool = false

// Optionally include kubernetesVersion in cluster properties
var maybeK8sVersion = empty(kubernetesVersion) ? {} : { kubernetesVersion: kubernetesVersion }
var networkContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

// Member VNets
resource memberVnets 'Microsoft.Network/virtualNetworks@2023-09-01' = [for (region, i) in memberRegions: {
  name: 'member-${region}-vnet'
  location: region
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.${i}.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: '10.${i}.0.0/20'
        }
      }
    ]
  }
}]

resource clusterIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [for region in memberRegions: if (tagAllLoadBalancers) {
  name: 'member-${region}-identity'
  location: region
}]

resource outboundPublicIPs 'Microsoft.Network/publicIPAddresses@2023-09-01' = [for region in memberRegions: if (tagAllLoadBalancers) {
  name: 'member-${region}-outbound-pip'
  location: region
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    ipTags: [
      {
        ipTagType: 'FirstPartyUsage'
        tag: '/Unprivileged'
      }
    ]
  }
}]

resource outboundPublicIPRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (region, i) in memberRegions: if (tagAllLoadBalancers) {
  name: guid(resourceGroup().id, region, 'outbound-pip-network-contributor')
  scope: outboundPublicIPs[i]
  properties: {
    principalId: clusterIdentities[i]!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleDefinitionId
  }
}]

resource memberVnetRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (region, i) in memberRegions: if (tagAllLoadBalancers) {
  name: guid(resourceGroup().id, region, 'vnet-network-contributor')
  scope: memberVnets[i]
  properties: {
    principalId: clusterIdentities[i]!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleDefinitionId
  }
}]

// Member AKS Clusters
resource memberClusters 'Microsoft.ContainerService/managedClusters@2023-10-01' = [for (region, i) in memberRegions: {
  name: 'member-${region}-${uniqueString(resourceGroup().id, region)}'
  location: region
  identity: tagAllLoadBalancers ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${clusterIdentities[i].id}': {}
    }
  } : {
    type: 'SystemAssigned'
  }
  properties: union({
    dnsPrefix: 'member-${region}-dns'
    agentPoolProfiles: [
      {
        name: 'agentpool'
        count: nodeCount
        vmSize: vmSize
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: memberVnets[i].properties.subnets[0].id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
      loadBalancerProfile: tagAllLoadBalancers ? {
        outboundIPs: {
          publicIPs: [
            {
              id: outboundPublicIPs[i].id
            }
          ]
        }
      } : null
      serviceCidr: '10.10${i}.0.0/16'
      dnsServiceIP: '10.10${i}.0.10'
    }
  }, maybeK8sVersion)
  dependsOn: [
    memberVnets[i]
    outboundPublicIPRoleAssignments
    memberVnetRoleAssignments
  ]
}]

output memberClusterNames array = [for i in range(0, length(memberRegions)): memberClusters[i].name]
output memberVnetNames array = [for i in range(0, length(memberRegions)): memberVnets[i].name]
