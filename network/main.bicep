//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  main.bicep — network
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Consolidated multi-environment model (NOSP-27 ADR-0001 / repo-local ADR-0003).
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
// Elmera IaC target region is westeurope (ks5cae's `location` param carries the same
// @allowed(['westeurope']) constraint).

@allowed(['westeurope'])
@description('The Azure region where the resources will be deployed.')
param location string = 'westeurope'

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Variables
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

var spokeName = '${environmentCode}-${workloadName}'
var networkRgName = '${spokeName}-network'

// Provenance reaches deployed resources through this tags object (D-45). `createdOn` is
// deliberately NOT minted here — the `[GOV]` Append policy owns it and resets it on every
// deploy, so it is never a creation record and Concierge must not create a second, competing
// source of truth for it (ADR-0003 "Also fixed on 2026-07-15", concierge-seeding-contract.md §5).
var tags = {
  orderId: orderId
  workload: workloadName
  environment: environmentCode
  requestedBy: requestedBy
  architypeVersion: architypeVersion
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Resource group
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource networkRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: networkRgName
  location: location
  tags: tags
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Network security groups
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Every rule is explicit source/destination/port. `vdcroot` carries 25 policy assignments
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
    securityRules: scalableSubnetSecurityRules
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
    dnsServers: []
    tags: tags
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
