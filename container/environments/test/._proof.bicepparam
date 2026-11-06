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

param subscriptionId = '00000000-0000-0000-0000-000000000000'
param workloadName = 'unittest'
param environmentCode = 't'
param environmentName = 'test'
param deployClientId = '00000000-0000-0000-0000-000000000000'
param managementGroupName = 'mg-test'
param vnetAddressPrefix = '10.0.0.0/25'
param subnetAddressPrefixes = [
  '10.0.0.0/27'
  '10.0.0.0/27'
]
param orderId = '12345'
param requestedBy = 'test@example.com'
param architypeVersion = '1.0.0'

param location = 'westeurope'

// createdOn of what already exists in the subscription, provided by the pipeline before the build
// (an object keyed by lower-cased resource id). No default on purpose: when the variable is not
// set the build fails, rather than every resource being given a new createdOn (modules/tags.bicep).
param existingTags = json(readEnvironmentVariable('EXISTING_TAGS'))

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
