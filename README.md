# concierge-architypes

IaC scaffold templates for [Innofactor Concierge](https://github.com/InnofactorOrg/concierge-app) —
the automated Azure landing zone provisioner.

When Concierge provisions a new Azure spoke it downloads an architype from this repository,
substitutes environment-specific tokens, and commits the result into the new spoke's Git repository
as the starting point for that environment's infrastructure-as-code.

This repository defines what every new customer environment looks like on day one. It is the
**MSP-shared** half of the architype split (LLD-17); customer-dedicated architypes live in that
customer's own IaC repository.

## How Concierge uses this repository

The `ArchitypesUri` application setting in the Concierge Function App points at this repository's
raw content base URL:

```
https://raw.githubusercontent.com/innofactororg/concierge-architypes/main
```

`dfa_NewSpoke05ConfigureSpoke` builds a download URL by appending the architype name and format
suffix to that base. Content is fetched anonymously — this repository is public and must stay
public for provisioning to work.

For a multi-file architype, `<architype>/manifest.json` declares the `source` → `target` pairs to
seed. Both halves are validated before anything is downloaded or committed: a `source` must stay
within the architype's own prefix, and a `target` must stay within the spoke repository root —
checked *after* `[#_..._#]` token substitution, so a token cannot expand into a traversal segment.

## The reserved token vocabulary, the manifest schema and the marker schema

The `[#_..._#]` substitution tokens, the architype `manifest.json` schema and the
`.concierge/workload.json` ownership-marker schema are documented once, in
[`docs/main/concierge-seeding-contract.md`](https://github.com/innofactororg/concierge-app/blob/main/docs/main/concierge-seeding-contract.md)
in the `concierge-app` repository — the repository that also holds the code enforcing it
(`Get-NewSpokeReservedToken`, `Test-NewSpokeReservedToken`). This README does not restate that
table: architype authors read the contract, not a second copy that can drift from it.

## Contents

Every architype below is manifest-driven (`manifest.json`, `schemaVersion` 1) — D-50 retires the
single-file seeding fallback, so every published architype carries a manifest, not only the
current default.

| Architype | Format | Notes |
|---|---|---|
| `network/` | Manifest (`schemaVersion` 1), Bicep | The **default** architype (`DefaultArchitype`): NOSP-27's consolidated multi-environment model — shared `main.bicep`, `environments/{env}/main.bicepparam` (folder-form), one `.pipelines/azure-pipeline.yaml`, `ps-rule.yaml`, `bicepconfig.json`. AVM from the Bicep public registry; no vendored `modules/` tree. |
| `network-terraform/` | Manifest (`schemaVersion` 1), Terraform | Terraform network architype. Declares no pipeline — Terraform under the consolidated model is deferred work. |
| `network-arm/` | Manifest (`schemaVersion` 1), ARM (`structureVersion 3.9.1`, `containerVersion 3.0.10`) + single-file Bicep | Azure-Deploy-era network architype — legacy for Azure Repos targets, where `bicep-action` is now the deployment engine (D-14). Preserved, not promoted; see [`network-arm/README.md`](network-arm/README.md). |

### Renamed from a prior published shape — breaking change for direct raw-URL consumers

The two pre-existing architypes were relocated by `git mv` (history preserved) so that `network/`
holds only the current consolidated Bicep model:

| Old raw path | New raw path |
|---|---|
| `{ArchitypesUri}/network/main.tf` | `{ArchitypesUri}/network-terraform/main.tf` |
| `{ArchitypesUri}/network/main.auto.tfvars` | `{ArchitypesUri}/network-terraform/main.auto.tfvars` |
| `{ArchitypesUri}/network.bicep` | `{ArchitypesUri}/network-arm/network.bicep` |
| `{ArchitypesUri}/network.json` | `{ArchitypesUri}/network-arm/network.json` |

Concierge itself addresses an architype by name (`Architype` app setting / per-request value), so
this is a rename, not a code change — but anything that fetched the **old raw paths directly**
(outside Concierge's own manifest-driven or single-file seeding logic) breaks the moment this
lands on `main`. See `02-12-SUMMARY.md` in `concierge-app`'s `.planning/` for the pre-merge
external-consumer check this rename required.

## What is deliberately not here

Bicep and Terraform are the go-forward deployment types. The 2020-era ARM files carrying
`configVersion 1.0.0.0` (`empty.json`, `iaas.json`, `paas.json`, `network-vdc-arm.json`) are
historical reference only, are **not** a build target, and were intentionally left out of this
repository rather than published as if they were current. They remain readable in the interim
staging repository's history if ever needed.

## Scheme requirement

`ArchitypesUri` must be `https://` for any remote host. Plaintext `http://` is accepted only for
loopback (`localhost`, `127.0.0.1`, `[::1]`) so a local architype server stays usable in
development — architype content becomes committed IaC that is later deployed with elevated Azure
credentials, so a remote cleartext origin is refused.
