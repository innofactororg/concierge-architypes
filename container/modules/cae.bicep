//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/cae.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// The Container Apps environment and the identity its apps run as, in the spoke's `-cae`
// resource group. Shape follows ks5cae: internal, workload profiles, peer traffic encrypted, a
// user-assigned identity for registry pull. Differences from ks5cae, both deliberate:
//   - Logs go to Azure Monitor through a diagnostic setting, not `log-analytics` with a shared
//     key. `listKeys()` on the central workspace would need a key-read grant in p-mgt for every
//     order's deploy identity; a diagnostic setting needs less, and nothing when left empty.
//   - The default-domain zone is always linked to the spoke VNet, and to the VNets in
//     `remoteVirtualNetworkResourceIds` only when given. Those remote links are what make the
//     apps resolvable from anywhere else: the spoke's DNS servers are the firewall proxy, which
//     forwards to the DCs, so it is the DC VNet's link (p-we1dc-network-vnet) that answers, not
//     the spoke's. ks5cae links the hub and DC VNets; each is a join on another subscription's
//     VNet, so it needs a platform grant (README, "Platform grants").
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Spoke name, {environmentCode}-{workloadName}.')
param spokeName string

@description('The Azure region where the resources will be deployed.')
param location string

@description('Delegated subnet for the environment (Microsoft.App/environments). /27 minimum for a workload-profiles environment.')
param infrastructureSubnetResourceId string

@description('Spoke VNet, for the default-domain private DNS zone link.')
param virtualNetworkResourceId string

@description('Further VNets to link the default-domain zone to (in Elmera: the hub and DC VNets). Cross-subscription; empty links the spoke only.')
param remoteVirtualNetworkResourceIds array

@description('Central Log Analytics workspace. Empty skips the diagnostic setting.')
param logAnalyticsWorkspaceResourceId string

@description('Also create the PostgreSQL Entra administrator identity. It lives here, one module above data.bicep, because the administrator resource is named by the principal id, which must be known when data.bicep starts.')
param createPostgreSqlAdminIdentity bool

@description('Resource tags.')
param tags object

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${spokeName}-cae-01-uami'
  location: location
  tags: tags
}

// Separate from the workload identity so the apps never run as database administrator.
resource postgreSqlAdminIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (createPostgreSqlAdminIdentity) {
  name: '${spokeName}-psql-01-admin-uami'
  location: location
  tags: tags
}

resource environment 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: '${spokeName}-cae-01'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetResourceId
      internal: true
    }
    // Workload profiles, not consumption-only: a consumption-only environment needs a /23 and
    // does not fit a /25 spoke.
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    peerTrafficConfiguration: {
      encryption: {
        enabled: true
      }
    }
    zoneRedundant: true
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: 'central-law'
  scope: environment
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// The default-domain zone takes its name from a runtime property of the environment, so it is
// deployed one module down (a resource name must be known at the start of the deployment).
module dns 'cae-dns.bicep' = {
  name: 'caeDnsDeploy'
  params: {
    defaultDomain: environment.properties.defaultDomain
    staticIp: environment.properties.staticIp
    spokeName: spokeName
    virtualNetworkResourceId: virtualNetworkResourceId
    remoteVirtualNetworkResourceIds: remoteVirtualNetworkResourceIds
    tags: tags
  }
}

output environmentResourceId string = environment.id
output defaultDomain string = environment.properties.defaultDomain
output staticIp string = environment.properties.staticIp
output identityResourceId string = identity.id
output identityPrincipalId string = identity.properties.principalId
output postgreSqlAdminIdentityResourceId string = createPostgreSqlAdminIdentity ? postgreSqlAdminIdentity!.id : ''
output postgreSqlAdminPrincipalId string = createPostgreSqlAdminIdentity ? postgreSqlAdminIdentity!.properties.principalId : ''
output postgreSqlAdminName string = createPostgreSqlAdminIdentity ? postgreSqlAdminIdentity!.name : ''
