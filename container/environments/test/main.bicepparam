// Reference per-environment parameter file for the `container` architype.
//
// Same canonical block as `network` (concierge-app docs/main/concierge-seeding-contract.md,
// schemaVersion 1): every reserved token is assigned to its canonical parameter name, and no
// token outside that vocabulary may appear here. The architype-local block below it carries the
// platform values, which are literals, not tokens: the ones in this master are neutral placeholders,
// and a tenant sets its own (hub addresses, central workspace, private DNS zones, client networks,
// SQL administrators) in its own copy of this architype.
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

// Estate tags, asked on the order form once per application (concierge-app order-tag contract).
param applicationName = '[#_tag.application_#]'
param ownerName = '[#_tag.owner.name_#]'
param ownerEmail = '[#_tag.owner.email_#]'
param costCenter = '[#_tag.costcenter_#]'
param serviceTier = '[#_tag.servicetier_#]'
param productTeam = '[#_tag.productteam_#]'
param spokeDescription = '[#_tag.description_#]'

// Subscription tags a tenant adds to the standard set. The whole subscription tag set is one PUT, so
// anything a tenant wants kept goes here, computed from the parameters above, for example
//   { kostnadAvdeling: costCenter, 'MSP-Enabled': 'true' }
param additionalSubscriptionTags = {}
param spokeLocationLabel = ''

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

// Placeholders: the tenant's hub firewall is both the DNS proxy (the spoke VNet resolves through it)
// and the 0.0.0.0/0 next hop. Replace both in the tenant's copy of this file.
param dnsServers = [
  '10.0.0.4'
]
param firewallPrivateIp = '10.0.0.4'

// Hub connectivity (default off, see the main.bicep note): the spoke side and the hub side of the
// peering, and the spoke route in the hub gateway route table, are written only when this is true.
param enableHubPeering = false
param hubNetworkSubscriptionId = ''
param hubNetworkResourceGroupName = ''
param hubVnetName = ''
param hubGatewayRouteTableName = ''

// Client networks (VPN and office) the hub firewall passes to the spoke; empty adds no NSG rule.
param clientNetworkAddressPrefixes = []

// Cross-subscription resources. The order's deploy identity holds a conditioned Owner on THIS
// subscription only, so each of these needs a platform grant before it can be set (README,
// "Platform grants"). Left empty, the template deploys without them.
param centralLogAnalyticsWorkspaceResourceId = ''
param dnsZoneLinkVirtualNetworkResourceIds = []
param privateDnsZoneResourceIds = {
  keyVault: ''
  postgreSql: ''
  sql: ''
}

// Databases are off until the workload team decides. Azure SQL is the estate default (one server and
// one database per environment, Entra only, administered by an Entra group); PostgreSQL follows the
// estate standard (PG18, private endpoint model, geo-redundant backup in production only, no HA).
param deployAzureSql = false
param sqlAdminGroupObjectId = ''
param sqlAdminGroupName = ''
param deployPostgreSql = false

// Container registry and GitHub OIDC identity for the environment (default off).
param deployDelivery = false
param githubOrg = ''
param githubOrgId = ''
param githubRepo = ''
param githubRepoId = ''
param githubSubjectSuffix = 'ref:refs/heads/main'
