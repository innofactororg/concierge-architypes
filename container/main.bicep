//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  main.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Container Apps spoke, modelled on ks5cae (the Bergen reference implementation): an internal,
// workload-profiles Container Apps environment in a firewalled spoke, a user-assigned identity
// for registry pull and Key Vault, and a private-endpoint-only Key Vault. The workload team
// builds the containers, pushes them to the shared platform registry and registers the apps on
// the environment; this template owns the platform layer only.
//
// The network layer is the `network` architype's, unchanged in name and order (PeFrontendSubnet
// = subnet 00, ScalableSubnet = subnet 01), so a spoke seeded as `network` can grow into this
// shape without renaming (and so recreating) a subnet. Added here: the firewall route table and
// the hub DNS servers on the VNet.
//
// Consolidated multi-environment model (NOSP-27 ADR-0001 / repo-local ADR-0003): this file does
// not change per environment, only `environments/{env}/main.bicepparam` does. Parameter names in
// the canonical block are fixed by the seeding contract (schemaVersion 1).
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
targetScope = 'subscription'

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Parameters — canonical (seeding contract)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Target subscription id. Not consumed directly — deployment scope is already the target subscription — but declared because the seeding contract requires every architype parameter file to assign it by canonical name.')
param subscriptionId string

@description('Workload name — the repository this environment belongs to. Used for resource naming and provenance tagging. At most 16 characters: `{env}-{workload}-kv-01` must fit the 24-character Key Vault limit (Concierge aliases are 6).')
@minLength(2)
@maxLength(16)
param workloadName string

@description('One-character environment code (d/t/p). Drives naming, and the production-only PostgreSQL settings.')
@allowed(['d', 't', 'p'])
param environmentCode string

@description('Long-form environment label (test/production). Carried for parameter-file conformance.')
param environmentName string

@description('Deploy client id. Not consumed by this template; declared for parameter-file conformance.')
param deployClientId string

@description('Management group the spoke subscription is placed under. Placement happens outside this template; declared for parameter-file conformance.')
param managementGroupName string

@description('Allocated VNet address prefix.')
param vnetAddressPrefix string

@description('Per-subnet address prefixes, in subnet declaration order: [0] PeFrontendSubnet (private endpoints), [1] ScalableSubnet (Container Apps environment, delegated, /27 minimum for workload profiles).')
param subnetAddressPrefixes array

@description('Provenance: the order identifier the request was raised under.')
param orderId string

@description('Provenance: who requested the provisioning run.')
param requestedBy string

@description('Provenance: the architype version the resource was seeded from.')
param architypeVersion string

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Parameters — architype-local
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Not part of the reserved-token vocabulary: literals in the parameter file.

@allowed(['westeurope'])
@description('The Azure region where the resources will be deployed.')
param location string = 'westeurope'

@description('DNS servers for the spoke VNet. In Elmera this is the hub firewall DNS proxy, which forwards to the DCs; the DC VNet is linked to every central private DNS zone, so the spoke needs no zone links of its own.')
param dnsServers array

@description('Private IP of the hub firewall: next hop for 0.0.0.0/0 on every spoke subnet.')
param firewallPrivateIp string

@description('Central Log Analytics workspace for Container Apps and Key Vault diagnostics. Cross-subscription: needs a platform grant (README). Empty skips diagnostics.')
param centralLogAnalyticsWorkspaceResourceId string = ''

@description('Central private DNS zones by service (keyVault, postgreSql). A private endpoint registers its A record in the zone named here. Cross-subscription: needs a platform grant (README). An empty value deploys the endpoint without a DNS zone group.')
param privateDnsZoneResourceIds object = {
  keyVault: ''
  postgreSql: ''
}

@description('VNets the Container Apps default-domain zone is linked to besides the spoke (in Elmera: the hub and DC VNets, so the apps resolve through the DCs). Cross-subscription: needs a platform grant (README). Empty links the spoke only, which on its own resolves nothing: the spoke\'s DNS is the firewall proxy, which forwards to the DCs.')
param dnsZoneLinkVirtualNetworkResourceIds array = []

@description('Deploy a PostgreSQL Flexible Server to the estate standard (NOSP-244).')
param deployPostgreSql bool = false

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Variables
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

var spokeName = '${environmentCode}-${workloadName}'
var networkRgName = '${spokeName}-network'
var caeRgName = '${spokeName}-cae'
var dataRgName = '${spokeName}-data'

// Provenance reaches deployed resources through this tags object (D-45). `createdOn` is owned by
// the [GOV] Append policy and deliberately not minted here.
var tags = {
  orderId: orderId
  workload: workloadName
  environment: environmentCode
  requestedBy: requestedBy
  architypeVersion: architypeVersion
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Resource groups
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource networkRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: networkRgName
  location: location
  tags: tags
}

resource caeRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: caeRgName
  location: location
  tags: tags
}

resource dataRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: dataRgName
  location: location
  tags: tags
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Network security groups
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// No any-any rule: `vdcroot` assigns `Deny-AnyAny-NSGRules`, which would make the template
// undeployable at the subscription this seeds into (D-56).

var baselineSecurityRules = [
  {
    name: 'DenyInternetInbound'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: 'Internet'
      destinationAddressPrefix: 'VirtualNetwork'
    }
  }
  {
    name: 'AllowVnetInbound'
    properties: {
      priority: 200
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'VirtualNetwork'
    }
  }
]

module peFrontendSubnetNsg 'br/public:avm/res/network/network-security-group:0.1.3' = {
  name: 'peFrontendSubnetNsgDeploy'
  scope: resourceGroup(networkRgName)
  dependsOn: [networkRg]
  params: {
    name: '${networkRgName}-vnet-PeFrontendSubnet-nsg'
    location: location
    securityRules: baselineSecurityRules
    tags: tags
  }
}

module scalableSubnetNsg 'br/public:avm/res/network/network-security-group:0.1.3' = {
  name: 'scalableSubnetNsgDeploy'
  scope: resourceGroup(networkRgName)
  dependsOn: [networkRg]
  params: {
    name: '${networkRgName}-vnet-ScalableSubnet-nsg'
    location: location
    securityRules: baselineSecurityRules
    tags: tags
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Route table — all egress through the hub firewall
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

module routeTable 'br/public:avm/res/network/route-table:0.2.2' = {
  name: 'routeTableDeploy'
  scope: resourceGroup(networkRgName)
  dependsOn: [networkRg]
  params: {
    name: '${networkRgName}-vnet-rt'
    location: location
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'Default-To-Firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
    tags: tags
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Virtual network
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.1.5' = {
  name: 'virtualNetworkDeploy'
  scope: resourceGroup(networkRgName)
  dependsOn: [networkRg]
  params: {
    name: '${networkRgName}-vnet'
    location: location
    addressPrefixes: [vnetAddressPrefix]
    dnsServers: dnsServers
    tags: tags
    subnets: [
      {
        name: 'PeFrontendSubnet'
        addressPrefix: subnetAddressPrefixes[0]
        networkSecurityGroupResourceId: peFrontendSubnetNsg.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: 'ScalableSubnet'
        addressPrefix: subnetAddressPrefixes[1]
        networkSecurityGroupResourceId: scalableSubnetNsg.outputs.resourceId
        routeTableResourceId: routeTable.outputs.resourceId
        delegations: [
          {
            name: 'Microsoft.App.environments'
            properties: {
              serviceName: 'Microsoft.App/environments'
            }
          }
        ]
      }
    ]
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Container Apps environment + identity
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

module cae 'modules/cae.bicep' = {
  name: 'caeDeploy'
  scope: resourceGroup(caeRgName)
  dependsOn: [caeRg]
  params: {
    spokeName: spokeName
    location: location
    infrastructureSubnetResourceId: '${virtualNetwork.outputs.resourceId}/subnets/ScalableSubnet'
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    remoteVirtualNetworkResourceIds: dnsZoneLinkVirtualNetworkResourceIds
    createPostgreSqlAdminIdentity: deployPostgreSql
    logAnalyticsWorkspaceResourceId: centralLogAnalyticsWorkspaceResourceId
    tags: tags
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Key Vault + optional PostgreSQL
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

module data 'modules/data.bicep' = {
  name: 'dataDeploy'
  scope: resourceGroup(dataRgName)
  dependsOn: [dataRg]
  params: {
    spokeName: spokeName
    location: location
    environmentCode: environmentCode
    privateEndpointSubnetResourceId: '${virtualNetwork.outputs.resourceId}/subnets/PeFrontendSubnet'
    privateDnsZoneResourceIds: privateDnsZoneResourceIds
    logAnalyticsWorkspaceResourceId: centralLogAnalyticsWorkspaceResourceId
    workloadIdentityPrincipalId: cae.outputs.identityPrincipalId
    postgreSqlAdminPrincipalId: cae.outputs.postgreSqlAdminPrincipalId
    postgreSqlAdminName: cae.outputs.postgreSqlAdminName
    deployPostgreSql: deployPostgreSql
    tags: tags
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Outputs — what the platform and the workload team need
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Container Apps environment the workload team registers its apps on.')
output containerAppsEnvironmentResourceId string = cae.outputs.environmentResourceId

@description('Internal default domain of the environment. Resolvable through the hub DNS only once the zone is linked to the DC VNet (dnsZoneLinkVirtualNetworkResourceIds).')
output containerAppsDefaultDomain string = cae.outputs.defaultDomain

@description('Internal load balancer IP: the WAF / hub DNS target if the workload is ever exposed.')
output containerAppsStaticIp string = cae.outputs.staticIp

@description('User-assigned identity apps run as. The platform grants it AcrPull on the shared registry (README, "Platform grants").')
output workloadIdentityResourceId string = cae.outputs.identityResourceId

@description('Principal id of the workload identity, for the shared-registry pull grant.')
output workloadIdentityPrincipalId string = cae.outputs.identityPrincipalId

@description('Key Vault for application secrets; the workload identity holds Key Vault Secrets User on it.')
output keyVaultUri string = data.outputs.keyVaultUri

@description('PostgreSQL Entra administrator identity, or empty when deployPostgreSql is false. Used once to grant the workload identity its database roles.')
output postgreSqlAdminIdentityResourceId string = cae.outputs.postgreSqlAdminIdentityResourceId

@description('PostgreSQL server FQDN, or empty when deployPostgreSql is false.')
output postgreSqlFqdn string = data.outputs.postgreSqlFqdn
