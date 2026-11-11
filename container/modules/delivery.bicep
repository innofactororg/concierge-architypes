//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//                                  modules/delivery.bicep — container
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// How the workload team's code gets onto the environment, in the spoke's `-cae` resource group:
//   - one container registry per environment (no shared registry);
//   - a GitHub identity the workflows log in as (OIDC federated credential, no secrets), separate
//     from the runtime identity the apps run as.
//
// Roles, least privilege:
//   - runtime identity:  AcrPull on the registry (apps pull their image).
//   - GitHub identity:   AcrPush on the registry, Container Apps Contributor on the `-cae` resource
//                        group (never the subscription), and Managed Identity Operator on the runtime
//                        identity only, so it can attach that identity to the apps it creates.
// The apps themselves are created and updated by the GitHub workflow, not by this repo, so an
// infrastructure deployment never rolls back an image.
//
// The registry keeps public network access on: GitHub-hosted runners push over the public endpoint.
// Admin user and anonymous pull are off, so only Entra identities with AcrPush/AcrPull can use it.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

import { withCreatedOn } from 'tags.bicep'

@description('Spoke name, {environmentCode}-{workloadName}.')
param spokeName string

@description('One-character environment code. With the workload name it forms the registry name, {env}{workload}cr.')
@allowed(['d', 't', 'p'])
param environmentCode string

@description('Workload name.')
@minLength(2)
@maxLength(16)
param workloadName string

@description('The Azure region where the resources will be deployed.')
param location string

@description('Name of the runtime identity the apps run as (cae.bicep), in this resource group.')
param runtimeIdentityName string

@description('Principal id of the runtime identity (AcrPull).')
param runtimeIdentityPrincipalId string

@description('Name of the federated credential on the GitHub identity.')
param githubCredentialName string

@description('OIDC subject the GitHub workflows deploy with, e.g. repo:{org}@{orgId}/{repo}@{repoId}:ref:refs/heads/main (GitHub sends org and repo ids in the subject).')
param githubSubject string

@description('Central Log Analytics workspace. Empty skips the registry diagnostic setting.')
param logAnalyticsWorkspaceResourceId string

@description('Tags every resource carries except createdOn.')
param baseTags object

@description('createdOn values of resources that already exist, keyed by lower-cased resource id (modules/tags.bicep).')
param existingTags object

@description('Deployment time, used as createdOn for a resource that does not exist yet.')
param now string

var githubIdentityName = '${spokeName}-github-uami'
var roleContainerAppsContributor = '358470bc-b998-42bd-ab17-a7e34c199c0f'
var roleManagedIdentityOperator = 'f1a07417-d97a-45cb-824c-7a7467783830'

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: runtimeIdentityName
}

// Identity the GitHub workflows log in as. No secrets: GitHub presents an OIDC token whose subject
// must match the federated credential exactly.
module githubIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'githubUamiDeploy'
  params: {
    location: location
    tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', githubIdentityName), now)
    name: githubIdentityName
    federatedIdentityCredentials: [
      {
        name: githubCredentialName
        issuer: 'https://token.actions.githubusercontent.com'
        subject: githubSubject
        audiences: [
          'api://AzureADTokenExchange'
        ]
      }
    ]
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: 'acrDeploy'
  params: {
    name: '${environmentCode}${workloadName}cr'
    location: location
    acrSku: 'Standard'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    // The module defaults to 'Deny', which sends a network rule set. Standard doesn't support one
    // (NetworkRuleNotSupported), and GitHub-hosted runners push over the public endpoint.
    networkRuleSetDefaultAction: 'Allow'
    diagnosticSettings: empty(logAnalyticsWorkspaceResourceId) ? [] : [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]
    roleAssignments: [
      {
        principalId: runtimeIdentityPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'AcrPull'
      }
      {
        principalId: githubIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'AcrPush'
      }
    ]
    tags: withCreatedOn(baseTags, existingTags, resourceId('Microsoft.ContainerRegistry/registries', '${environmentCode}${workloadName}cr'), now)
  }
}

// GitHub deploys app revisions in this resource group. Scoped to the resource group, not the
// subscription. The name is built from known values: a role assignment name cannot use a runtime
// output such as the principal id.
resource githubContainerAppsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, githubIdentityName, roleContainerAppsContributor)
  properties: {
    principalId: githubIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleContainerAppsContributor)
    description: 'GitHub Actions deploys container app revisions'
  }
}

// GitHub attaches the runtime identity to the apps it creates, which needs Managed Identity
// Operator on that identity only.
resource githubManagedIdentityOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(runtimeIdentity.id, githubIdentityName, roleManagedIdentityOperator)
  scope: runtimeIdentity
  properties: {
    principalId: githubIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleManagedIdentityOperator)
    description: 'GitHub Actions attaches the runtime identity to the apps it creates'
  }
}

output registryLoginServer string = containerRegistry.outputs.loginServer
output githubIdentityClientId string = githubIdentity.outputs.clientId
output githubIdentityResourceId string = githubIdentity.outputs.resourceId
