# Governance changes, R1

Applies to the `container` and `network` architypes. Provenance: validated against the Concierge test landing zone; opaque reference `Validated: NOSD-2523`. No customer detail belongs in this repository.

## 1. Deployment stacks, cost estimate, partner attribution

- `DEPLOYMENT_MODE: stack`, `STACK_ACTION_ON_UNMANAGE: detachAll`, `STACK_DENY_SETTINGS_MODE: none`, stack name left at its default (the repository name). There is no delete mode: a resource removed from the template is released, not deleted. The what-if may list resources as "unsupported" or "detach" where a name is only known at deploy time (the Container Apps DNS records, the Key Vault role assignment); under `detachAll` that is expected and harmless.
- Cost estimate: `VERSION_ACE: '1.6.5'`, `COST_THRESHOLD: -1` (report only). If the estimator fails on a template the error is kept; the version is not blanked.
- Partner attribution: one fixed id, `pid-d40f4895-5a21-5612-aa15-69cd25571694`, an inline empty nested deployment at subscription scope in every `main.bicep`, deployed on every run, no parameter, no condition. A deployment name at subscription scope is bound to its location, so it stays on the template's own deployment location (`location`, westeurope only); deploying it later from another location would fail.

## 2. Tags

Keys are PascalCase with no duplicates (tag names are case-insensitive). The lowercase `workload` and `environment` are replaced by `Application` (the workload name) and `Environment` (`Test`, `Production`, `Development`, derived from the environment code). The provenance tags `orderId`, `requestedBy`, `architypeVersion` stay. `Owner`, `OwnerEmail`, `CostCenter`, `ServiceTier` need order inputs that are not supplied yet and are added with the order-tag contract.

**Modules and tags.** Every taggable resource in both architypes receives the tag set, including `createdOn`. The three AVM modules (`network-security-group` 0.1.3, `route-table` 0.2.2, `virtual-network` 0.1.5) each pass `tags` to their main resource; none of them drops it. Not taggable, so not tagged: subnets, routes, NSG rules, role assignments, diagnostic settings, DNS records, private DNS zone groups. Azure-created resources (private endpoint network interfaces) are not tagged by the template; the Container Apps managed resource group receives the environment's tags from the platform.

### Decision: `createdOn` is owned by the infrastructure code, per resource (supersedes D-45)

The `[GOV]` Append policy cannot own it: a policy evaluates the incoming request, and every deployment PUTs the resource with a tag set that has no `createdOn`, so each deployment stamps the time of that deployment.

A bare `param createdOn string = utcNow()` has the same defect: `utcNow()` is evaluated on every deployment. The value must be minted once and then preserved, and Bicep cannot ask whether a resource already exists (`existing` fails when it does not, `utcNow()` is only valid as a parameter default).

Mechanism (bicep-action "Existing tags", innofactororg/bicep-action#43): the pipeline variable `EXISTING_TAGS_KEYS: createdOn` makes the pipeline read that tag from what already exists, before every compile in the plan and again before the deploy, and provide it as the environment variable `EXISTING_TAGS`: `{ "<lower-cased resource id>": { "createdOn": "<value>" } }`. `modules/tags.bicep` (`network` keeps the same function inline) is `withCreatedOn(tags, existing, id, now)`: a resource's existing value wins, and `now` (a parameter default, ISO 8601 like the existing tags) is used only for a resource that is not in the object. Resource group ids are built as `${subscription().id}/resourceGroups/<name>` (not `subscriptionResourceId`, which never matches); lookups are lower-cased on both sides. The parameter file reads the variable **without a default** (`json(readEnvironmentVariable('EXISTING_TAGS'))`), so a pipeline without `EXISTING_TAGS_KEYS` fails the compile; it never re-stamps. Granularity is one value per taggable resource the template declares.

There is no "last deployed" tag: it would show a change in every plan and fail the snapshot check on every run. The deployment history and the bicep-action logs record the last deployment.

## 3. `ScalableSubnet` and `PeFrontendSubnet`: `privateEndpointNetworkPolicies`

`ScalableSubnet` now sets `privateEndpointNetworkPolicies: 'Disabled'` explicitly. The module sent `null`, Azure kept the live value (`Disabled`), and what-if compared against the API default (`Enabled`), so every plan reported a change that never happens.

Evidence (Microsoft Learn):
- *Manage network policies for private endpoints*: "This setting only applies to private endpoints in the subnet and affects all private endpoints in the subnet. For other resources in the subnet, access is controlled based on security rules in the network security group." `ScalableSubnet` holds no private endpoint, so the value has no effect on traffic; `Disabled` equals the live value and so changes nothing on an existing deployment. https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy
- *Configure virtual networks in Azure Container Apps environments*: a workload-profile environment needs a `/27` or larger subnet delegated to `Microsoft.App/environments`; the page states no requirement on private endpoint network policies for that subnet. https://learn.microsoft.com/azure/container-apps/custom-virtual-networks

**`PeFrontendSubnet` (proposal, not changed here).** It stays `Disabled`. With `Disabled` the subnet's NSG and route table do not apply to traffic to the private endpoints in it (same page). Findings:
- `NetworkSecurityGroupEnabled` would make the existing NSG (deny from Internet, allow from VirtualNetwork) apply to endpoint traffic. It is the low-risk step and is the proposed value.
- `RouteTableEnabled` only changes routing if a route with a prefix equal to or smaller than the VNet address space points at the firewall: the page states a `0.0.0.0/0` route "won't override private endpoint routes" (the endpoint's `/32` wins by longest prefix match). Forcing endpoint traffic through the firewall therefore needs an extra route and brings asymmetric-routing risk. Not proposed without a decision on inspection.
- Test required before any change: the Container App reads a Key Vault secret through the private endpoint after the switch, and the NSG flow shows the intended path. Not run in this change.

## 4. Private-only audit

| Resource | Public access setting | Private path | Status |
|---|---|---|---|
| Key Vault | `publicNetworkAccess: Disabled`, `networkAcls.defaultAction: Deny`, `bypass: AzureServices` | Private endpoint in `PeFrontendSubnet`, DNS zone group when a zone id is given | Private. Open item for the architect: `bypass: AzureServices` stays because Microsoft trusted services (not Azure DevOps) can then reach the vault without a private endpoint; Microsoft documents that disabling public access does not suppress that bypass. Setting `None` is stricter but would block those services |
| Container Apps environment | `vnetConfiguration.internal: true`, `publicNetworkAccess: Disabled` (explicit) | Internal load balancer in the delegated subnet; no public inbound IP | Private. The explicit property is new: confirm on the first deployment onto an existing environment that the update is accepted |
| PostgreSQL Flexible Server (optional) | `network.publicNetworkAccess: Disabled`, Entra auth only, password auth disabled | Private endpoint (the estate standard model), created in `PeFrontendSubnet` | Private. The networking mode is create-time-only; a VNet-integrated server could never take a private endpoint, so moving between modes is a rebuild |
| Virtual network, NSGs, route table | n/a | All egress `0.0.0.0/0` to the hub firewall | Private |
| Private DNS zone (apps default domain) | n/a (global, linked to VNets only) | VNet links | Private |
| Managed identities | n/a | n/a | n/a |
| Storage, registries, other PaaS | none in these architypes | the container registry is shared and platform-owned | out of scope |

## 5. Decision record: Key Vault reached from Container Apps

**Decision:** the private endpoint stays.

| Option | Public endpoint still exists | Meets "nothing public" | Notes |
|---|---|---|---|
| Private endpoint (current) | No, with public access disabled | Yes | Costs one endpoint plus DNS. Reaches the vault through a private IP |
| Service endpoint plus firewall "selected networks" | Yes, restricted to the subnet | No | Needs public access enabled for the selected networks; conflicts with the "disable public network access" policies |
| Network Security Perimeter | Yes, governed by perimeter rules | No | Governs public access only; "Private endpoint traffic ... isn't subject to Network Security Perimeter rules", it gives no private IP path |

Source: Microsoft Learn, *Configure network security for Azure Key Vault*. https://learn.microsoft.com/azure/key-vault/general/network-security . No supported fully private option without a private endpoint was found.

### createdOn and the snapshot: only the spoke's own resource groups (NOSD-2532)

The Bicep snapshot writes every parameter value it expands, and `existingTags` is used inside every resource's tags expression, so the snapshot used to contain the whole `EXISTING_TAGS` object: platform resource groups too (network watcher, the Container Apps managed group, monitoring). A change to any of them failed the snapshot check of a template that had not changed (shown with a negative control). The parameter file now keeps only the entries whose resource id is a resource group the template declares or sits under one (`<env>-<workload>-network`, `-cae`, `-data`; `-network` for the network architype), computed from `subscriptionId`, `environmentCode` and `workloadName`, so the filter runs when the parameter file is compiled and the snapshot never sees the rest. Checked on the map of a real test subscription (18 entries): the snapshot made from the full map and the one made from the map without the network watcher, managed and monitoring group entries have the same content, and a snapshot validates against a map that gained an unrelated platform entry. Repositories seeded earlier keep their old files until a pull request updates them.

### Explicit values for service-reported properties (what-if noise)

`availabilityZones` of the Container Apps environment is now stated (`1`, `2`, `3`, the zones of a zone-redundant environment), so the plan no longer reports it as a removal. Two properties are deliberately NOT set: `peerAuthentication.mtls.enabled` reads `false` on the live environment next to `peerTrafficConfiguration.encryption.enabled: true`; the two are older and newer names of the same setting, and stating `false` beside `true` could switch peer encryption off, so it stays unset until it is tested on a throwaway environment. `isIPv6EnabledPrivateEndpoint` of the Key Vault private endpoint is reported by Azure but is not in the Bicep type of any `Microsoft.Network/privateEndpoints` API version up to 2025-05-01 (BCP037), so it cannot be stated. Both remain as noise in the stack what-if (one modify on each resource).
