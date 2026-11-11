//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  main.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Container Apps spoke, modelled on an established reference spoke: an internal,
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
// Consolidated multi-environment model: this file does
// not change per environment, only `environments/{env}/main.bicepparam` does. Parameter names in
// the canonical block are fixed by the seeding contract (schemaVersion 1).
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
targetScope = 'subscription'

import { withCreatedOn } from 'modules/tags.bicep'

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

@description('DNS servers for the spoke VNet. Typically the hub firewall DNS proxy, which forwards to the domain controllers; their VNet is linked to every central private DNS zone, so the spoke needs no zone links of its own.')
param dnsServers array

@description('Private IP of the hub firewall: next hop for 0.0.0.0/0 on every spoke subnet.')
param firewallPrivateIp string

@description('Central Log Analytics workspace for Container Apps and Key Vault diagnostics. Cross-subscription: needs a platform grant (README). Empty skips diagnostics.')
param centralLogAnalyticsWorkspaceResourceId string = ''

@description('Central private DNS zones by service (keyVault, postgreSql, sql). A private endpoint registers its A record in the zone named here. Cross-subscription: needs a platform grant (README). An empty value deploys the endpoint without a DNS zone group.')
param privateDnsZoneResourceIds object = {
  keyVault: ''
  postgreSql: ''
  sql: ''
}

@description('VNets the Container Apps default-domain zone is linked to besides the spoke (typically the hub and domain-controller VNets, so the apps resolve through them). Cross-subscription: needs a platform grant (README). Empty links the spoke only, which on its own resolves nothing: the spoke\'s DNS is the firewall proxy, which forwards to the DCs.')
param dnsZoneLinkVirtualNetworkResourceIds array = []

@description('Deploy a PostgreSQL Flexible Server (private endpoint model, Entra only).')
param deployPostgreSql bool = false

@description('Deploy an Azure SQL server and database (the estate default for a workload database).')
param deployAzureSql bool = false

@description('Object id of the Entra group that administers the SQL server (Entra-only authentication). Required when deployAzureSql is true.')
param sqlAdminGroupObjectId string = ''

@description('Display name of the Entra group that administers the SQL server. Required when deployAzureSql is true.')
param sqlAdminGroupName string = ''

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Parameters — order-supplied estate tags
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Asked on the order form once per application (concierge-app order-tag contract) and carried
// into the parameter file by the tag tokens. None has a default: a wrong cost centre is
// worse than a failed order.

@description('Application name, the `Application` tag (cost reporting and ownership).')
param applicationName string

@description('Name of the person accountable for the application, the `Owner` tag.')
param ownerName string

@description('Email of the owner, the `OwnerEmail` tag.')
param ownerEmail string

@description('Cost centre the spoke is billed to, the `CostCenter` tag.')
param costCenter string

@description('Service tier of the application, the `ServiceTier` tag.')
@allowed(['Silver', 'Gold', 'Platinum'])
param serviceTier string

@description('Product team that owns and manages the spoke, the subscription `ProductTeam` tag: the name of its Entra group without the tenant\'s group prefix.')
param productTeam string

@description('Free-text description of what the spoke hosts, the subscription `Description` tag.')
param spokeDescription string

@description('Extra subscription tags a tenant adds to the standard set (the whole set is written as one PUT, so every tag the subscription should keep is listed here or above). A tenant\'s own parameter file computes these from the parameters above.')
param additionalSubscriptionTags object = {}

@description('Where the spoke lives, for the subscription `Purpose` tag ("This subscription is a \'t\' spoke in the <label>"). Empty leaves the sentence without a place.')
param spokeLocationLabel string = ''

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Parameters — hub connectivity (default off)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Who writes the hub side of a spoke's peering and route is not decided (LLD-96). Until it is, the
// spoke deploys without any hub write: enableHubPeering is false and the values below stay empty.

@description('Peer the spoke VNet with the hub and add the spoke route to the hub gateway route table. Both directions are written by this deployment, so the deploy identity needs write access on the hub network resource group. Default off.')
param enableHubPeering bool = false

@description('Subscription that holds the hub network. Required when enableHubPeering is true.')
param hubNetworkSubscriptionId string = ''

@description('Resource group of the hub network. Required when enableHubPeering is true.')
param hubNetworkResourceGroupName string = ''

@description('Name of the hub VNet. Required when enableHubPeering is true.')
param hubVnetName string = ''

@description('Name of the hub gateway-subnet route table that carries a route per spoke. Required when enableHubPeering is true.')
param hubGatewayRouteTableName string = ''

@description('Client networks (VPN and office) the hub firewall passes to the spoke. Their source address is not in the VirtualNetwork tag, so the Container Apps subnet NSG needs an explicit allow for them. Empty: no such rule.')
param clientNetworkAddressPrefixes array = []

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Parameters — delivery (default off)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Deploy a container registry for the environment and a GitHub OIDC identity that pushes to it and deploys apps. Default off; the values below are required only when it is on.')
param deployDelivery bool = false

@description('GitHub organisation that owns the workload repository.')
param githubOrg string = ''

@description('Numeric id of the GitHub organisation. GitHub puts it in the OIDC subject.')
param githubOrgId string = ''

@description('Name of the GitHub repository whose workflows deploy to this environment.')
param githubRepo string = ''

@description('Numeric id of the GitHub repository. GitHub puts it in the OIDC subject.')
param githubRepoId string = ''

@description('Which workflows may log in: the part of the OIDC subject after the repository, e.g. ref:refs/heads/main, pull_request or environment:production.')
param githubSubjectSuffix string = 'ref:refs/heads/main'

@description('createdOn of the resources that already exist, keyed by lower-cased resource id. The parameter file reads it from the EXISTING_TAGS environment variable the pipeline provides before the build, with no default, so a missing value fails the build and never re-stamps (modules/tags.bicep).')
param existingTags object

@description('Deployment time: the createdOn of a resource that does not exist yet. utcNow() is only valid as a parameter default; it must never be used as the tag value of a resource that already exists.')
param now string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Variables
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

var spokeName = '${environmentCode}-${workloadName}'
var networkRgName = '${spokeName}-network'
var caeRgName = '${spokeName}-cae'
var dataRgName = '${spokeName}-data'

// Tags follow the estate standard: PascalCase keys, no duplicates (tag names are case-insensitive,
// so a lowercase variant of an existing key is the same key). Environment is derived, not collected.
// The provenance tags (orderId, requestedBy, architypeVersion) stay (D-45). createdOn is added per
// resource by `withCreatedOn` (modules/tags.bicep).
var environmentLabel = environmentCode == 'p' ? 'Production' : (environmentCode == 't' ? 'Test' : 'Development')

var tags = {
  Application: applicationName
  Environment: environmentLabel
  Owner: ownerName
  OwnerEmail: ownerEmail
  CostCenter: costCenter
  ServiceTier: serviceTier
  orderId: orderId
  requestedBy: requestedBy
  architypeVersion: architypeVersion
}

// Subscription tags: the level cost reporting reads. The resource tags above (without createdOn, which
// is a property of a resource) plus ProductTeam, SubscriptionRole, Purpose and Description, plus
// whatever a tenant adds in additionalSubscriptionTags.
// Tags/default is a PUT: ARM replaces the subscription's whole tag set, so list every tag the
// subscription should carry. A tag added by hand on the subscription is removed on the next deploy.
var subscriptionTags = union(tags, {
  ProductTeam: productTeam
  SubscriptionRole: 'Spoke'
  Purpose: 'This subscription is a \'${environmentCode}\' spoke${empty(spokeLocationLabel) ? '' : ' in the ${spokeLocationLabel}'}.'
  Description: spokeDescription
}, additionalSubscriptionTags)

var hubVnetResourceId = enableHubPeering ? resourceId(hubNetworkSubscriptionId, hubNetworkResourceGroupName, 'Microsoft.Network/virtualNetworks', hubVnetName) : ''

// GitHub's OIDC subject carries the organisation and repository ids, so a renamed or recreated
// repository does not match (a name-only subject fails with AADSTS700213).
var githubSubject = 'repo:${githubOrg}@${githubOrgId}/${githubRepo}@${githubRepoId}:${githubSubjectSuffix}'

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Subscription tags
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource subscriptionTagSet 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  properties: {
    tags: subscriptionTags
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Partner attribution
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Mandatory in every template Innofactor writes: an empty nested deployment with the fixed
// partner id, deployed on every run, so Microsoft attributes the consumption. No parameter and no
// condition. It is separate from AVM's own `enableTelemetry`.
//
// A deployment name at subscription scope is bound to the location of its first deployment: the
// same name deployed later from a different location fails. It is therefore kept on this
// template's own deployment location, the `location` parameter (westeurope only, @allowed), the
// same location the pipeline's IN_LOCATION uses for the deployment record. Changing either one
// of them later would make this deployment fail.
#disable-next-line no-deployments-resources // inline by design: the fixed partner id must not depend on a module or registry
resource partnerAttribution 'Microsoft.Resources/deployments@2022-09-01' = {
  name: 'pid-d40f4895-5a21-5612-aa15-69cd25571694'
  location: location
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      resources: []
      outputs: {
        telemetry: {
          type: 'String'
          value: 'For more information, see https://aka.ms/partnerattribution'
        }
      }
    }
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Resource groups
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource networkRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: networkRgName
  location: location
  tags: withCreatedOn(tags, existingTags, '${subscription().id}/resourceGroups/${networkRgName}', now)
}

resource caeRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: caeRgName
  location: location
  tags: withCreatedOn(tags, existingTags, '${subscription().id}/resourceGroups/${caeRgName}', now)
}

resource dataRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: dataRgName
  location: location
  tags: withCreatedOn(tags, existingTags, '${subscription().id}/resourceGroups/${dataRgName}', now)
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Network security groups
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// No any-any rule: the estate's root management group assigns a policy that denies any-any NSG rules, which would make the template
// undeployable at the subscription this seeds into (D-56).

var baselineSecurityRules = [
  {
    name: 'DenyInternetInbound'
    properties: {
      priority: 110
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

// Client networks arrive through the hub firewall with their own source address, which is not in the
// VirtualNetwork tag, so without this rule the NSG drops them at the internal load balancer of the
// Container Apps environment. Private endpoints ignore the NSG, so the PeFrontendSubnet needs nothing.
// 31443 as well as 443: in a workload-profiles Container Apps environment the internal load balancer
// forwards 443 to node port 31443 (envoy-https), and the NSG sees the port after the load balancer,
// so 443 alone is dropped.
// Priority 100 on purpose: the client networks are outside the VirtualNetwork tag, so
// DenyInternetInbound matches them and must come after this allow (it is 110).
var scalableSubnetSecurityRules = empty(clientNetworkAddressPrefixes) ? baselineSecurityRules : concat(baselineSecurityRules, [
  {
    name: 'AllowHttpsFromClientNetworks'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRanges: ['443', '31443']
      sourceAddressPrefixes: clientNetworkAddressPrefixes
      destinationAddressPrefix: 'VirtualNetwork'
      description: 'HTTPS from the client networks (VPN, office) to the Container Apps environment'
    }
  }
])

module peFrontendSubnetNsg 'br/public:avm/res/network/network-security-group:0.1.3' = {
  name: 'peFrontendSubnetNsgDeploy'
  scope: resourceGroup(networkRgName)
  dependsOn: [networkRg]
  params: {
    name: '${networkRgName}-vnet-PeFrontendSubnet-nsg'
    location: location
    securityRules: baselineSecurityRules
    tags: withCreatedOn(tags, existingTags, resourceId(subscription().subscriptionId, networkRgName, 'Microsoft.Network/networkSecurityGroups', '${networkRgName}-vnet-PeFrontendSubnet-nsg'), now)
  }
}

module scalableSubnetNsg 'br/public:avm/res/network/network-security-group:0.1.3' = {
  name: 'scalableSubnetNsgDeploy'
  scope: resourceGroup(networkRgName)
  dependsOn: [networkRg]
  params: {
    name: '${networkRgName}-vnet-ScalableSubnet-nsg'
    location: location
    securityRules: scalableSubnetSecurityRules
    tags: withCreatedOn(tags, existingTags, resourceId(subscription().subscriptionId, networkRgName, 'Microsoft.Network/networkSecurityGroups', '${networkRgName}-vnet-ScalableSubnet-nsg'), now)
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
    tags: withCreatedOn(tags, existingTags, resourceId(subscription().subscriptionId, networkRgName, 'Microsoft.Network/routeTables', '${networkRgName}-vnet-rt'), now)
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
    tags: withCreatedOn(tags, existingTags, resourceId(subscription().subscriptionId, networkRgName, 'Microsoft.Network/virtualNetworks', '${networkRgName}-vnet'), now)
    // Peering to the hub, both directions (the hub side needs a platform grant), only when
    // enableHubPeering. The VPN gateway is in the hub: this spoke uses it (useRemoteGateways), the
    // hub offers it (gateway transit).
    peerings: enableHubPeering ? [
      {
        name: hubVnetName
        remoteVirtualNetworkId: hubVnetResourceId
        remotePeeringName: '${networkRgName}-vnet'
        remotePeeringEnabled: true
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: true
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: false
        remotePeeringAllowGatewayTransit: true
        remotePeeringUseRemoteGateways: false
        // AVM defaults these to true, but Azure only persists false. Pinned so what-if converges
        // instead of showing a change on the hub peering every run.
        doNotVerifyRemoteGateways: false
        remotePeeringDoNotVerifyRemoteGateways: false
      }
    ] : []
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
        // Explicit, not left to the module default: the module sends null, Azure keeps the
        // subnet's live value, and what-if compares against the API default (Enabled), so every
        // plan reported a change that never happens. `Disabled` is the live value and costs
        // nothing here: this subnet holds no private endpoints, only the delegated Container
        // Apps environment. See docs/governance-r1.md, section 3, for the Microsoft documentation.
        privateEndpointNetworkPolicies: 'Disabled'
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
//                                  Hub route for the spoke range (only with enableHubPeering)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

module hubRoute 'modules/hub-route.bicep' = if (enableHubPeering) {
  name: '${spokeName}-hubRouteDeploy'
  scope: resourceGroup(hubNetworkSubscriptionId, hubNetworkResourceGroupName)
  params: {
    routeTableName: hubGatewayRouteTableName
    routeName: virtualNetwork.outputs.name
    addressPrefix: vnetAddressPrefix
    nextHopIpAddress: firewallPrivateIp
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
    baseTags: tags
    existingTags: existingTags
    now: now
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Registry + GitHub identity (only with deployDelivery)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

module delivery 'modules/delivery.bicep' = if (deployDelivery) {
  name: 'deliveryDeploy'
  scope: resourceGroup(caeRgName)
  dependsOn: [caeRg]
  params: {
    spokeName: spokeName
    environmentCode: environmentCode
    workloadName: workloadName
    location: location
    runtimeIdentityName: '${spokeName}-cae-01-uami'
    runtimeIdentityPrincipalId: cae.outputs.identityPrincipalId
    githubCredentialName: 'github-${githubOrg}-${githubRepo}'
    githubSubject: githubSubject
    logAnalyticsWorkspaceResourceId: centralLogAnalyticsWorkspaceResourceId
    baseTags: tags
    existingTags: existingTags
    now: now
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Key Vault + optional Azure SQL / PostgreSQL
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
    deployAzureSql: deployAzureSql
    sqlAdminGroupObjectId: sqlAdminGroupObjectId
    sqlAdminGroupName: sqlAdminGroupName
    baseTags: tags
    existingTags: existingTags
    now: now
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

@description('Azure SQL server FQDN, or empty when deployAzureSql is false.')
output sqlServerFqdn string = data.outputs.sqlServerFqdn

@description('Azure SQL database name, or empty when deployAzureSql is false.')
output sqlDatabaseName string = data.outputs.sqlDatabaseName

@description('Login server of the environment\'s container registry, or empty when deployDelivery is false.')
output containerRegistryLoginServer string = deployDelivery ? delivery!.outputs.registryLoginServer : ''

@description('Client id of the GitHub identity (the `client-id` the workflow passes to azure/login), or empty when deployDelivery is false.')
output githubIdentityClientId string = deployDelivery ? delivery!.outputs.githubIdentityClientId : ''
