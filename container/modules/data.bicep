//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/data.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Key Vault (always), plus Azure SQL and/or PostgreSQL Flexible Server (each optional), in the
// spoke's `-data` resource group. All are private-endpoint only, in PeFrontendSubnet.
//
// Azure SQL is the estate default for a workload database (PostgreSQL only when a workload needs it):
//   - one logical server and one database per environment.
//   - Entra authentication only, the administrator is an Entra group: no SQL password to seed,
//     store or rotate. The workload identity is not the administrator; the administrators grant it
//     its own database roles after deployment (a contained user, not IaC).
//   - public network access Disabled, minimum TLS 1.2, reached through a private endpoint.
//   - test: General Purpose serverless (auto-pause), locally redundant backup.
//   - production: General Purpose provisioned, geo-redundant backup (create-time-only).
//
// PostgreSQL follows the estate standard:
//   - private endpoint model: created in public-access mode with public access Disabled, plus a
//     private endpoint. Never VNet-integrated: networking mode is create-time-only, and a
//     VNet-integrated server can never take a private endpoint .
//   - PostgreSQL 18.
//   - geo-redundant backup in EVERY environment, from creation (create-time-only: it cannot be
//     switched on later). Burstable takes it (the estate's own Burstable Standard_B1ms servers run
//     with it), so the tier does not decide it.
//   - an explicit availability zone and Advanced Threat Protection on, as on the estate's servers.
//   - no HA (out of scope estate-wide).
//   - GeneralPurpose in production, Burstable elsewhere (size, not backup).
//   - Entra authentication only: no password to seed, store or rotate. The administrator is a
//     dedicated identity, not the workload identity, so the apps do not run as database admin;
//     the admin grants the workload identity its own database roles.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

import { withCreatedOn } from 'tags.bicep'

@description('Spoke name, {environmentCode}-{workloadName}.')
param spokeName string

@description('The Azure region where the resources will be deployed.')
param location string

@description('One-character environment code. `p` turns on the production PostgreSQL settings.')
@allowed(['d', 't', 'p'])
param environmentCode string

@description('Subnet the private endpoints are placed in.')
param privateEndpointSubnetResourceId string

@description('Central private DNS zones by service (keyVault, postgreSql, sql). Empty: no DNS zone group.')
param privateDnsZoneResourceIds object

@description('Central Log Analytics workspace. Empty skips the diagnostic settings.')
param logAnalyticsWorkspaceResourceId string

@description('Principal id of the workload identity (Key Vault Secrets User).')
param workloadIdentityPrincipalId string

@description('Principal id of the PostgreSQL Entra administrator identity (created in cae.bicep). Empty when deployPostgreSql is false.')
param postgreSqlAdminPrincipalId string

@description('Name of the PostgreSQL Entra administrator identity.')
param postgreSqlAdminName string

@description('Availability zone of the PostgreSQL server, stated explicitly as on the estate\'s servers. Create-time-only: changing it moves the server.')
@allowed(['1', '2', '3'])
param postgreSqlAvailabilityZone string = '1'

@description('Deploy the PostgreSQL Flexible Server.')
param deployPostgreSql bool

@description('Deploy the Azure SQL server and database.')
param deployAzureSql bool

@description('Object id of the Entra group that administers the SQL server. Required when deployAzureSql is true.')
param sqlAdminGroupObjectId string

@description('Display name of the Entra group that administers the SQL server. Required when deployAzureSql is true.')
param sqlAdminGroupName string

@description('Tags every resource carries except createdOn.')
param baseTags object

@description('createdOn values of resources that already exist, keyed by lower-cased resource id (modules/tags.bicep).')
param existingTags object

@description('Deployment time, used as createdOn for a resource that does not exist yet.')
param now string

var isProduction = environmentCode == 'p'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Key Vault
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${spokeName}-kv-01'
  location: location
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.KeyVault/vaults', '${spokeName}-kv-01'), now)
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
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Network/privateEndpoints', '${spokeName}-kv-01-pe'), now)
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

resource postgreSql 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (deployPostgreSql) {
  name: '${spokeName}-psql-01'
  location: location
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.DBforPostgreSQL/flexibleServers', '${spokeName}-psql-01'), now)
  sku: {
    name: isProduction ? 'Standard_D2ds_v5' : 'Standard_B1ms'
    tier: isProduction ? 'GeneralPurpose' : 'Burstable'
  }
  properties: {
    version: '18'
    // Explicit, as on the estate's servers; create-time-only (a change moves the server).
    availabilityZone: postgreSqlAvailabilityZone
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Enabled' // every environment; create-time-only
    }
    highAvailability: {
      mode: 'Disabled'
    }
    // A custom window rather than the platform's random one. Sunday 02:00 UTC.
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

resource postgreSqlThreatProtection 'Microsoft.DBforPostgreSQL/flexibleServers/advancedThreatProtectionSettings@2024-08-01' = if (deployPostgreSql) {
  parent: postgreSql
  name: 'Default'
  properties: {
    state: 'Enabled'
  }
}

resource postgreSqlAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = if (deployPostgreSql) {
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
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Network/privateEndpoints', '${spokeName}-psql-01-pe'), now)
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

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  Azure SQL (optional)
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Backup storage redundancy is create-time-only: changing it later is a rebuild (copy or restore),
// not a pipeline run.

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = if (deployAzureSql) {
  name: '${spokeName}-sql-01'
  location: location
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Sql/servers', '${spokeName}-sql-01'), now)
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: sqlAdminGroupName
      sid: sqlAdminGroupObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = if (deployAzureSql) {
  parent: sqlServer
  name: '${spokeName}-sqldb-01'
  location: location
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Sql/servers/databases', '${spokeName}-sql-01', '${spokeName}-sqldb-01'), now)
  sku: isProduction ? {
    name: 'GP_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  } : {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368 // 32 GB
    zoneRedundant: false
    // Customer-controlled window (Azure.SQL.MaintenanceWindow): the platform's overnight weekday
    // window rather than a random one. Same intent as the PostgreSQL custom window .
    maintenanceConfigurationId: subscriptionResourceId('Microsoft.Maintenance/publicMaintenanceConfigurations', 'SQL_WestEurope_DB_1')
    requestedBackupStorageRedundancy: isProduction ? 'Geo' : 'Local' // create-time-only
    autoPauseDelay: isProduction ? null : 60 // serverless (test) only
    minCapacity: isProduction ? null : json('0.5') // serverless (test) only
  }
}

// Defender for SQL on the server, matching the subscription plan (Azure.SQL.DefenderCloud).
resource sqlSecurityAlertPolicy 'Microsoft.Sql/servers/securityAlertPolicies@2023-08-01' = if (deployAzureSql) {
  parent: sqlServer
  name: 'Default'
  properties: {
    state: 'Enabled'
    emailAccountAdmins: false
  }
}

// Vulnerability assessment, express configuration (no storage account). Defender for SQL turns it
// on for new servers anyway; declaring it keeps IaC and Defender in step (Azure.SQL.VAScan).
resource sqlVulnerabilityAssessment 'Microsoft.Sql/servers/sqlVulnerabilityAssessments@2023-08-01' = if (deployAzureSql) {
  parent: sqlServer
  name: 'default'
  dependsOn: [sqlSecurityAlertPolicy]
  properties: {
    state: 'Enabled'
  }
}

resource sqlEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (deployAzureSql) {
  name: '${spokeName}-sql-01-pe'
  location: location
  tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.Network/privateEndpoints', '${spokeName}-sql-01-pe'), now)
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: '${spokeName}-sql-01-pe'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: ['sqlServer']
        }
      }
    ]
  }
}

resource sqlDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (deployAzureSql && !empty((privateDnsZoneResourceIds.?sql ?? ''))) {
  parent: sqlEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: (privateDnsZoneResourceIds.?sql ?? '')
        }
      }
    ]
  }
}

output keyVaultUri string = keyVault.properties.vaultUri
output postgreSqlFqdn string = deployPostgreSql ? postgreSql!.properties.fullyQualifiedDomainName : ''
output sqlServerFqdn string = deployAzureSql ? sqlServer!.properties.fullyQualifiedDomainName : ''
output sqlDatabaseName string = deployAzureSql ? sqlDatabase!.name : ''
