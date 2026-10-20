//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/cae-dns.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Private DNS for an internal Container Apps environment: *.{defaultDomain} -> the environment's
// static IP. Linked to the spoke VNet always, and to remoteVirtualNetworkResourceIds when given
// (see cae.bicep for why the DC VNet link is the one that answers).
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Default domain of the Container Apps environment.')
param defaultDomain string

@description('Static IP of the environment internal load balancer.')
param staticIp string

@description('Spoke name, {environmentCode}-{workloadName}.')
param spokeName string

@description('Spoke VNet.')
param virtualNetworkResourceId string

@description('Further VNets to link the zone to. Cross-subscription.')
param remoteVirtualNetworkResourceIds array

@description('Resource tags.')
param tags object

// An internal environment's apps resolve at *.{defaultDomain} to the environment's static IP.
resource defaultDomainZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: defaultDomain
  location: 'global'
  tags: tags
}

resource wildcardRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: defaultDomainZone
  name: '*'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: staticIp
      }
    ]
  }
}

resource apexRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: defaultDomainZone
  name: '@'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: staticIp
      }
    ]
  }
}

resource spokeLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: defaultDomainZone
  name: '${spokeName}-network-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkResourceId
    }
  }
}

resource remoteLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in remoteVirtualNetworkResourceIds: {
    parent: defaultDomainZone
    name: '${last(split(vnetId, '/'))}-link'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

