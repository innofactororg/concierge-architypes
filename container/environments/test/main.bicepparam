// Reference per-environment parameter file for the `container` architype.
//
// Same canonical block as `network` (concierge-app docs/main/concierge-seeding-contract.md,
// schemaVersion 1): every reserved token is assigned to its canonical parameter name, and no
// token outside that vocabulary may appear here. The architype-local block below it carries
// Elmera platform values that are literals, not tokens.
//
// `using` points at the shared main.bicep as it sits in the seeded repository (two levels up from
// `environments/{env}/`).
using '../../main.bicep'

param subscriptionId = '[#_service.subscription.id_#]'
param workloadName = '[#_service.name_#]'
param environmentCode = '[#_service.environment_#]'
param environmentName = '[#_service.environmentName_#]'
param deployClientId = '[#_service.deployclient.id_#]'
param managementGroupName = '[#_service.managementgroup_#]'
param vnetAddressPrefix = '[#_service.vnet.addressPrefix_#]'
param subnetAddressPrefixes = [
  '[#_service.vnet.subnet.00.addressPrefix_#]'
  '[#_service.vnet.subnet.01.addressPrefix_#]'
]
param orderId = '[#_provenance.orderId_#]'
param requestedBy = '[#_provenance.requestedBy_#]'
param architypeVersion = '[#_provenance.architypeVersion_#]'

param location = 'westeurope'

// Elmera hub: the p-we1net firewall is both the DNS proxy (spoke VNets resolve through it to the
// DCs, which are linked to every central private DNS zone) and the 0.0.0.0/0 next hop.
param dnsServers = [
  '10.126.1.4'
]
param firewallPrivateIp = '10.126.1.4'

// Cross-subscription resources. The order's deploy identity holds a conditioned Owner on THIS
// subscription only, so each of these needs a platform grant before it can be set (README,
// "Platform grants"). Left empty, the template deploys without them.
param centralLogAnalyticsWorkspaceResourceId = ''
param dnsZoneLinkVirtualNetworkResourceIds = []
param privateDnsZoneResourceIds = {
  keyVault: ''
  postgreSql: ''
}

// Off until the workload team decides on a database. PostgreSQL follows the estate standard
// (NOSP-244): PG18, private endpoint model, geo-redundant backup in production only, no HA.
param deployPostgreSql = false
