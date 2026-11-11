//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/cae-dns.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Private DNS for an internal Container Apps environment: *.{defaultDomain} -> the environment's
// static IP. Linked to the spoke VNet always, and to remoteVirtualNetworkResourceIds when given
// (see cae.bicep for why the DC VNet link is the one that answers).
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

import { withCreatedOn } from 'tags.bicep'

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

@description('Tags every resource carries except createdOn.')
param baseTags object

@description('createdOn values of resources that already exist, keyed by lower-cased resource id (modules/tags.bicep).')
param existingTags object

@description('Deployment time, used as createdOn for a resource that does not exist yet.')
param now string

// An internal environment's apps resolve at *.{defaultDomain} to the environment's static IP.
resource defaultDomainZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: defaultDomain
  location: 'global'
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Network/privateDnsZones', defaultDomain), now)
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
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Network/privateDnsZones/virtualNetworkLinks', defaultDomain, '${spokeName}-network-vnet-link'), now)
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
    tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Network/privateDnsZones/virtualNetworkLinks', defaultDomain, '${last(split(vnetId, '/'))}-link'), now)
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

