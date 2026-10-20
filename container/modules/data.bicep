//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/data.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Key Vault (always) and PostgreSQL Flexible Server (optional), in the spoke's `-data` resource
// group. Both are private-endpoint only, in PeFrontendSubnet.
//
// PostgreSQL follows the estate standard Kamran's NOSP-244 rebuilds are converging on:
//   - private endpoint model: created in public-access mode with public access Disabled, plus a
//     private endpoint. Never VNet-integrated: networking mode is create-time-only, and a
//     VNet-integrated server can never take a private endpoint (NOSD-2371).
//   - PostgreSQL 18.
//   - geo-redundant backup in production only (create-time-only; test stays LRS, NOSD-2462).
//   - no HA (out of scope estate-wide, Rune).
//   - GeneralPurpose in production: Burstable cannot take geo-redundant backup.
//   - Entra authentication only: no password to seed, store or rotate. The administrator is a
//     dedicated identity, not the workload identity, so the apps do not run as database admin;
//     the admin grants the workload identity its own database roles.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@description('Spoke name, {environmentCode}-{workloadName}.')
param spokeName string

@description('The Azure region where the resources will be deployed.')
param location string

@description('One-character environment code. `p` turns on the production PostgreSQL settings.')
@allowed(['d', 't', 'p'])
param environmentCode string

@description('Subnet the private endpoints are placed in.')
param privateEndpointSubnetResourceId string

@description('Central private DNS zones by service (keyVault, postgreSql). Empty: no DNS zone group.')
param privateDnsZoneResourceIds object

@description('Central Log Analytics workspace. Empty skips the diagnostic settings.')
param logAnalyticsWorkspaceResourceId string

@description('Principal id of the workload identity (Key Vault Secrets User).')
param workloadIdentityPrincipalId string

@description('Principal id of the PostgreSQL Entra administrator identity (created in cae.bicep). Empty when deployPostgreSql is false.')
param postgreSqlAdminPrincipalId string

@description('Name of the PostgreSQL Entra administrator identity.')
param postgreSqlAdminName string

@description('Deploy the PostgreSQL Flexible Server.')
param deployPostgreSql bool

@description('Resource tags.')
param tags object

var isProduction = environmentCode == 'p'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Key Vault
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${spokeName}-kv-01'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, workloadIdentityPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: workloadIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: 'central-law'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'audit'
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

resource keyVaultEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${keyVault.name}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: '${keyVault.name}-pe'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource keyVaultDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (!empty((privateDnsZoneResourceIds.?keyVault ?? ''))) {
  parent: keyVaultEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: (privateDnsZoneResourceIds.?keyVault ?? '')
        }
      }
    ]
  }
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  PostgreSQL Flexible Server (optional)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Every property below marked create-time-only cannot be changed on a running server; changing
// it later is a rebuild (dump/restore or PITR), not a pipeline run.

resource postgreSql 'Microsoft.DBforPostgreSQL/flexibleServers@2025-06-01-preview' = if (deployPostgreSql) {
  name: '${spokeName}-psql-01'
  location: location
  tags: tags
  sku: {
    name: isProduction ? 'Standard_D2ds_v5' : 'Standard_B1ms'
    tier: isProduction ? 'GeneralPurpose' : 'Burstable'
  }
  properties: {
    version: '18'
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: isProduction ? 'Enabled' : 'Disabled' // create-time-only
    }
    highAvailability: {
      mode: 'Disabled'
    }
    // A custom window rather than the platform's random one (NOSP-239). Sunday 02:00 UTC.
    maintenanceWindow: {
      customWindow: 'Enabled'
      dayOfWeek: 0
      startHour: 2
      startMinute: 0
    }
    network: {
      publicNetworkAccess: 'Disabled' // private endpoint model; create-time-only
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: tenant().tenantId
    }
  }
}

resource postgreSqlAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-06-01-preview' = if (deployPostgreSql) {
  parent: postgreSql
  name: postgreSqlAdminPrincipalId
  properties: {
    principalName: postgreSqlAdminName
    principalType: 'ServicePrincipal'
    tenantId: tenant().tenantId
  }
}

resource postgreSqlDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployPostgreSql && !empty(logAnalyticsWorkspaceResourceId)) {
  name: 'central-law'
  scope: postgreSql
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

resource postgreSqlEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (deployPostgreSql) {
  name: '${spokeName}-psql-01-pe'
  // Serialised behind the administrator: both operate on the server, and in parallel the second
  // can fail with ServerIsBusy.
  dependsOn: [postgreSqlAdmin]
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: '${spokeName}-psql-01-pe'
        properties: {
          privateLinkServiceId: postgreSql.id
          groupIds: ['postgresqlServer']
        }
      }
    ]
  }
}

resource postgreSqlDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (deployPostgreSql && !empty((privateDnsZoneResourceIds.?postgreSql ?? ''))) {
  parent: postgreSqlEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-postgres-database-azure-com'
        properties: {
          privateDnsZoneId: (privateDnsZoneResourceIds.?postgreSql ?? '')
        }
      }
    ]
  }
}

output keyVaultUri string = keyVault.properties.vaultUri
output postgreSqlFqdn string = deployPostgreSql ? postgreSql!.properties.fullyQualifiedDomainName : ''
