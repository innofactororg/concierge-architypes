# container

A Container Apps spoke: the [`network`](../network/main.bicep) layer (same subnets, same order)
plus a firewall route table and hub DNS servers, an internal zone-redundant workload-profiles
Container Apps environment with a user-assigned workload identity, a private-endpoint-only Key
Vault, and an optional PostgreSQL Flexible Server. The workload team builds the images, pushes
them to the tenant's shared platform registry and registers the apps on the environment. This
architype owns the platform layer only: it creates no container registry and no apps.

See [`../README.md`](../README.md) for how Concierge seeds an architype, and
[`docs/main/concierge-seeding-contract.md`](https://github.com/innofactororg/concierge-app/blob/main/docs/main/concierge-seeding-contract.md)
in `concierge-app` for the manifest and token schema. This file is documentation only and is not
listed in `manifest.json`, so it is not copied into the spoke repository.

## What it deploys

All resources are deployed at subscription scope into three resource groups named
`{env}-{workload}-network`, `-cae` and `-data`.

| Resource group | Resources |
|---|---|
| `-network` | VNet with `PeFrontendSubnet` (private endpoints) and `ScalableSubnet` (delegated to `Microsoft.App/environments`); one NSG per subnet; one route table, associated with both subnets, sending `0.0.0.0/0` to `firewallPrivateIp` (virtual appliance, BGP propagation disabled). The VNet's DNS servers are the `dnsServers` parameter. |
| `-cae` | Internal Container Apps environment (`Consumption` workload profile, zone redundant, peer traffic encrypted); user-assigned workload identity `{env}-{workload}-cae-01-uami`; optionally the PostgreSQL Entra administrator identity (`deployPostgreSql`); the environment's default-domain private DNS zone, linked to the spoke VNet and to any VNets in `dnsZoneLinkVirtualNetworkResourceIds`; an optional diagnostic setting to the central Log Analytics workspace. |
| `-data` | Key Vault (private endpoint only; the workload identity holds Key Vault Secrets User); optionally a PostgreSQL Flexible Server (`deployPostgreSql`); diagnostic settings for both when a central workspace is given. |

Outputs include `workloadIdentityResourceId` and `workloadIdentityPrincipalId` (the identity the
apps run as and the principal that needs registry pull rights), `containerAppsEnvironmentResourceId`
and `keyVaultUri`.

## Order-supplied estate tags

Every resource group and resource carries `Application`, `Environment` (derived), `Owner`, `OwnerEmail`, `CostCenter`, `ServiceTier`, the provenance tags (`orderId`, `requestedBy`, `architypeVersion`) and a `createdOn` that is minted once per resource. The subscription itself carries the same set plus `ProductTeam`, `SubscriptionRole`, `Purpose` and `Description`, and whatever a tenant adds in `additionalSubscriptionTags`. The subscription tags are written as one `Microsoft.Resources/tags` PUT, which replaces the whole set: a tag added by hand is removed on the next deploy, so list every tag you want kept.

The tag values arrive through the order-tag tokens in `environments/{env}/main.bicepparam` (`applicationName`, `ownerName`, `ownerEmail`, `costCenter`, `serviceTier`, `productTeam`, `spokeDescription`). None has a default.

## Optional parts (all default off)

| Parameter | What it adds |
|---|---|
| `deployAzureSql` (+ `sqlAdminGroupObjectId`, `sqlAdminGroupName`) | One Azure SQL server and database, Entra-only, administered by the named group, private endpoint. |
| `deployPostgreSql` | The PostgreSQL Flexible Server described above. |
| `deployDelivery` (+ the `github*` parameters) | A registry for the environment and a GitHub OIDC identity that pushes to it and deploys apps. |
| `enableHubPeering` (+ the `hub*` parameters) | Peering with the hub VNet in both directions and the spoke route in the hub gateway route table. Both directions are written by this deployment, so the deploy identity needs write access on the hub network resource group. Who should write the hub side is an open decision; keep it off until it is made. |
| `clientNetworkAddressPrefixes` | An NSG allow (443 and 31443) for client networks that reach the spoke through the hub firewall. |

## Platform grants

Everything this architype needs outside its own subscription is a platform grant. The table lives
in one place, [Platform grants for `container`](../README.md#platform-grants-for-container) in the
root README, and is not repeated here. The registry pull grant is described under
[Container images and the shared registry](#container-images-and-the-shared-registry) below.

## Container images and the shared registry

### What the template does and does not do

- Apps pull from the tenant's **shared platform registry** using the workload identity
  (`workloadIdentityResourceId`), which needs `AcrPull` on that registry. The template outputs the
  principal id; it does not create the role assignment, because the registry is in another
  subscription (root README, "Platform grants").
- The template creates **no registry** and **no private endpoint or private DNS record for one**.
  `privateDnsZoneResourceIds` carries only `keyVault` and `postgreSql`.
- The template creates **no apps**, so it does not set the `registries` identity binding on any
  app. The workload team's app definitions must reference the workload identity as the registry
  identity, otherwise the pull is attempted anonymously and fails.

### The registry must already hold every image

Container Apps pulls an image when a revision is created. Every base image and application image
the team builds on must therefore already be in the shared registry **before the first app
deployment**, at the exact tag the app references.

The recommended pattern is a git-driven import repository owned by the platform:

1. A team opens a pull request adding a pinned image entry (source image and tag, target
   repository and tag).
2. After review, a pipeline runs `az acr import` to copy that image into the shared registry.
3. App Dockerfiles and app definitions use `FROM <registry>/<image>:<pinned tag>`: never `latest`,
   and never a public registry directly.

This keeps builds reproducible, keeps public registries out of the build and runtime path, and
gives one reviewed place to see which upstream images the estate depends on.

### Why imports fail with 429 TOOMANYREQUESTS

`az acr import` does not bypass Docker Hub's limits. The import service pulls from the source
registry anonymously unless it is given credentials, and Docker Hub limits unauthenticated pulls
per source IP address (see [Docker Hub usage and limits](https://docs.docker.com/docker-hub/usage/pulls/)
for the current figure). ACR's import service, and Microsoft-hosted or other shared build agents,
all egress from shared address ranges, so the allowance is consumed by other tenants as well. A
single import usually succeeds, which is why the problem tends to appear only when several new
tags arrive at once, and then fails with `429 TOOMANYREQUESTS`.

Two ways to avoid it:

- **Source Docker Official Images from the AWS ECR Public mirror**:
  `public.ecr.aws/docker/library/<image>:<tag>`. It is anonymous, so no secret is needed.
  Unauthenticated pulls are rate limited and capped per month, and the limits can change: check
  the [current AWS limits](https://docs.aws.amazon.com/AmazonECR/latest/public/public-service-quotas.html)
  before relying on it for a large batch. Only the Docker Official Images are mirrored this way;
  other publishers' images are not.
- **Authenticate to Docker Hub** with a Docker Hub account and a read-only personal access token.
  Store the token as a secret in a pipeline variable group, map it explicitly into the step's
  environment (secret variables are not exposed to scripts automatically), and pass it to the
  import as `--username` and `--password`. ACR Artifact Cache needs the same credential.

### Failure signatures

| What the team sees | Likely cause |
|---|---|
| Container app revision fails to provision; image pull error containing `manifest unknown` | The tag was never imported into the shared registry, or the app references a different repository or tag than the one imported. |
| Revision fails with an unauthorized / authentication error on pull | `AcrPull` has not been granted to `workloadIdentityPrincipalId`, or the app definition does not bind the workload identity as its registry identity. |
| Revision fails with a timeout or name-resolution error on the registry host | The environment cannot reach the registry: see the reachability notes below. |
| Import or image build fails with `429 TOOMANYREQUESTS` from Docker Hub | Anonymous pulls from shared egress hit the Docker Hub limit: use the ECR Public mirror or authenticate. |

### Registry reachability from the spoke

What the template provides:

- A route table on **both** subnets, including the Container Apps environment's infrastructure
  subnet, sending `0.0.0.0/0` to the hub firewall. Registry traffic (and Microsoft container
  registry and Entra ID traffic during environment provisioning) therefore transits the firewall.
- `dnsServers` on the VNet, set in the environment parameter file to the hub firewall, which acts
  as a DNS proxy. A private registry's `privatelink` name resolves only if the central private DNS
  zone for it is reachable from that proxy's upstream resolvers.
- Outbound rules in the NSGs are not restricted: the baseline NSG rules are inbound only, so the
  Azure default outbound rules apply.

What it does not provide, and so is part of the platform and hub change:

- A **firewall rule** allowing the environment's subnet to reach the registry (its private
  endpoint address, or its public name if reached publicly), and the Microsoft container
  registry and Entra ID destinations the environment needs to provision.
- **DNS for the registry's private endpoint**: the zone link or forwarding that makes the
  registry's name resolve to its private address from the spoke. The template links no zone for
  the registry.
- **Private endpoint connectivity itself**: the registry's private endpoint is owned by whoever
  owns the registry; the template cannot create or approve it.
- The hub IPAM record (`hub/ipam-spoke.yaml`) carries nothing that marks this as a Container Apps
  spoke, so the hub change reviewer has to be told.

### Onboarding checklist for a new spoke

- [ ] The shared registry holds every base and app image the team needs, at pinned tags, **before
      the first app deployment** (import repository merged and its pipeline run).
- [ ] `AcrPull` granted to `workloadIdentityPrincipalId` on the shared registry.
- [ ] App definitions bind the workload identity (`workloadIdentityResourceId`) as the registry
      identity.
- [ ] Hub change merged first: firewall rules from the Container Apps subnet to the registry and
      to the destinations the environment needs to provision.
- [ ] The registry name resolves from the spoke through the hub DNS proxy, and the registry
      endpoint is reachable from `ScalableSubnet` (test with a first revision before onboarding
      the real workload).
- [ ] Docker Hub is not in any build or import path without credentials; official images come
      from the ECR Public mirror or an authenticated import.
