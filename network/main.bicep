//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  main.bicep — network
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Consolidated multi-environment model.
// Shared across every environment: this file does not change per environment —
// only `environments/{env}/main.bicepparam` does.
//
// Parameter names below are canonical (concierge-app docs/main/concierge-seeding-contract.md,
// schemaVersion 1). An architype whose parameter file does not use these exact names is
// rejected by Concierge's seeding contract — the names are not this architype's choice.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
targetScope = 'subscription'

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Parameters — canonical (seeding contract)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Target subscription id. Not consumed directly by this template — deployment scope is already the target subscription via the pipeline/CLI context — but declared because the seeding contract requires every architype parameter file to assign it by canonical name.')
param subscriptionId string

@description('Workload name — the repository this environment belongs to. Used for resource naming and provenance tagging.')
param workloadName string

@description('One-character environment code (d/t/p) used for subscription naming and provenance tagging.')
@allowed(['d', 't', 'p'])
param environmentCode string

@description('Long-form environment label (test/production) used for content paths. Not consumed by this template directly; carried for parameter-file conformance and available to downstream tooling.')
param environmentName string

@description('Deploy client id. Not consumed by this template — the deploy identity and its RBAC grant are Phase 2.1 plumbing (D-58), out of scope for this architype — but declared for parameter-file conformance.')
param deployClientId string

@description('Management group name the spoke subscription is placed under. Not consumed by this template — subscription-to-management-group placement happens outside this template, before deployment — but declared for parameter-file conformance.')
param managementGroupName string

@description('Allocated VNet address prefix.')
param vnetAddressPrefix string

@description('Per-subnet address prefixes, in subnet declaration order: [0] PeFrontendSubnet, [1] ScalableSubnet.')
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
// Not part of the reserved-token vocabulary. A literal default is fine — every current
// target region is westeurope (the reference spokes' `location` param carries the same
// @allowed(['westeurope']) constraint).

@allowed(['westeurope'])
@description('The Azure region where the resources will be deployed.')
param location string = 'westeurope'

@description('createdOn of the resources that already exist, keyed by lower-cased resource id. The parameter file reads it from the EXISTING_TAGS environment variable the pipeline provides before the build, with no default, so a missing value fails the build and never re-stamps.')
param existingTags object

@description('Deployment time: the createdOn of a resource that does not exist yet. utcNow() is only valid as a parameter default; it must never be used as the tag value of a resource that already exists.')
param now string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Variables
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

var spokeName = '${environmentCode}-${workloadName}'
var networkRgName = '${spokeName}-network'

// `createdOn` is owned by the infrastructure code, per resource: minted once, when the resource is
// first created, and carried unchanged afterwards. `utcNow()` alone would record the LAST
// deployment, and the [GOV] Append policy evaluates the request, so it stamps the deployment time
// too. The pipeline reads the `createdOn` of what already exists before the build and provides it
// as EXISTING_TAGS (an object keyed by lower-cased resource id); a resource that is not in it
// yet takes `now`. Kept in this file because this architype seeds a single template; the
// `container` architype shares the same function from modules/tags.bicep.
func withCreatedOn(tags object, existing object, id string, now string) object =>
  union(tags, { createdOn: existing[?toLower(id)].?createdOn ?? now })

// Tags follow the estate standard: PascalCase keys, no duplicates (tag names are case-insensitive).
// Application and Environment replace the lowercase `workload` and `environment` this template
// used to carry. The provenance tags stay (D-45). Owner, OwnerEmail, CostCenter and ServiceTier
// need order inputs Concierge does not supply yet.
var environmentLabel = environmentCode == 'p' ? 'Production' : (environmentCode == 't' ? 'Test' : 'Development')

var tags = {
  Application: workloadName
  Environment: environmentLabel
  orderId: orderId
  requestedBy: requestedBy
  architypeVersion: architypeVersion
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
//                                  Resource group
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource networkRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: networkRgName
  location: location
  tags: withCreatedOn(tags, existingTags, '${subscription().id}/resourceGroups/${networkRgName}', now)
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Network security groups
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Every rule is explicit source/destination/port. the root management group carries many policy assignments
// including `Deny-AnyAny-NSGRules` — an any-any rule (source AND destination address prefix
// both `*` together with destination port `*`) makes this template undeployable by policy at
// the subscription this seeds into, and is the first thing 02-14's conformance test checks
// (D-56).

var peFrontendSubnetSecurityRules = [
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

var scalableSubnetSecurityRules = [
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
    securityRules: peFrontendSubnetSecurityRules
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
    dnsServers: []
    tags: withCreatedOn(tags, existingTags, resourceId(subscription().subscriptionId, networkRgName, 'Microsoft.Network/virtualNetworks', '${networkRgName}-vnet'), now)
    subnets: [
      {
        name: 'PeFrontendSubnet'
        addressPrefix: subnetAddressPrefixes[0]
        networkSecurityGroupResourceId: peFrontendSubnetNsg.outputs.resourceId
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: 'ScalableSubnet'
        addressPrefix: subnetAddressPrefixes[1]
        networkSecurityGroupResourceId: scalableSubnetNsg.outputs.resourceId
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
