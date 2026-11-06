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

// Not a reserved token — every current Elmera IaC target region is westeurope. Assigned
// explicitly (rather than left to the default) to match the reference implementations'
// convention of one parameter per line, and so a future non-westeurope region is a one-line
// change to this file rather than a main.bicep edit.
param location = 'westeurope'

// createdOn of what already exists in the subscription, provided by the pipeline before the build
// (an object keyed by lower-cased resource id). No default on purpose: when the variable is not
// set the build fails, rather than every resource being given a new createdOn.
param existingTags = json(readEnvironmentVariable('EXISTING_TAGS'))
