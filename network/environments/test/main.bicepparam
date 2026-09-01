// Reference per-environment parameter file for the `network` architype.
//
// Folder-form (`environments/{env}/main.bicepparam`) is this architype's layout — it diverges
// from the NOSP-27 reference implementations' file-form (`environments/test.bicepparam`,
// `environments/production.bicepparam`). See the "NOSP-27 refinement note" in
// `02-11-SUMMARY.md` for the proposed refinement and who it is raised with (D-12).
//
// Every value below is either a literal or a reserved substitution token from
// concierge-app's docs/main/concierge-seeding-contract.md (schemaVersion 1). No token outside
// that vocabulary may appear in this file — `Test-NewSpokeReservedToken` enforces it.
//
// `using` points at the shared main.bicep as it sits in the *seeded repository* (two levels up
// from `environments/{env}/`), not as it sits inside this architype folder — the two paths are
// identical by construction (`network/environments/test/` -> `network/main.bicep` here; the
// seeded repo root's `environments/test/` -> the seeded repo root's `main.bicep` there).
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

// Not a reserved token — every current Elmera IaC target region is westeurope. Assigned
// explicitly (rather than left to the default) to match the reference implementations'
// convention of one parameter per line, and so a future non-westeurope region is a one-line
// change to this file rather than a main.bicep edit.
param location = 'westeurope'
