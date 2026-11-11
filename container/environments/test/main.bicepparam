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

// createdOn of what already exists in the subscription, provided by the pipeline before the build
// (an object keyed by lower-cased resource id). No default on purpose: when the variable is not
// set the build fails, rather than every resource being given a new createdOn (modules/tags.bicep).
//
// Only the entries under this spoke's own resource groups are kept. The snapshot check writes every
// parameter value into the snapshot, so the platform's resource groups (network watcher, the
// Container Apps managed group, monitoring) must not be part of this value: a change to any of
// them would otherwise fail the snapshot check of a template that did not change.
var existingTagsAll = json(readEnvironmentVariable('EXISTING_TAGS'))
var ownedResourceGroups = [
  toLower('/subscriptions/${subscriptionId}/resourceGroups/${environmentCode}-${workloadName}-network')
  toLower('/subscriptions/${subscriptionId}/resourceGroups/${environmentCode}-${workloadName}-cae')
  toLower('/subscriptions/${subscriptionId}/resourceGroups/${environmentCode}-${workloadName}-data')
]
param existingTags = toObject(
  filter(items(existingTagsAll), e => length(filter(ownedResourceGroups, rg => e.key == rg || startsWith(e.key, '${rg}/'))) > 0),
  e => e.key,
  e => e.value
)

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
