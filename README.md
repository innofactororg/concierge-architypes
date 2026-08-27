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

## Contents

| Path | Format | Notes |
|---|---|---|
| `network.json` | ARM (`structureVersion 3.9.1`, `containerVersion 3.0.10`) | Current network architype |
| `network.bicep` | Bicep | Current network architype |
| `network/main.tf`, `network/main.auto.tfvars` | Terraform | Current network architype |

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
