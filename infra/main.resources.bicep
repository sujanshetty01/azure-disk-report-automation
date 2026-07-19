// ============================================================================
// Azure Storage Cost Remediation v2 — Resource Module
// ============================================================================
// Deploys within the resource group:
//   - Shared Storage Account + Blob Container
//   - Application Insights
//   - Linux Function App (Consumption Plan)
//   - Windows Function App (Consumption Plan)
//   - Logic App (Consumption) with full workflow
//   - Storage RBAC for both Function App MSIs
// ============================================================================

param location string
param nameSuffix string
param tags object

// ─── Derived Names ──────────────────────────────────────────────────────────

var storageAccountName = 'diskreportsa${nameSuffix}'
var linuxFuncAppName = 'diskreport-linux-${nameSuffix}'
var windowsFuncAppName = 'diskreport-win-${nameSuffix}'
var linuxPlanName = 'diskreport-linux-plan-${nameSuffix}'
var windowsPlanName = 'diskreport-win-plan-${nameSuffix}'
var appInsightsName = 'diskreport-ai-${nameSuffix}'
var logicAppName = 'diskreport-logic-${nameSuffix}'
var blobContainerName = 'disk-reports'

// Storage Blob Data Contributor role
var storageBlobContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

// ============================================================================
// 1. STORAGE ACCOUNT
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource reportContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: blobContainerName
  properties: { publicAccess: 'None' }
}

// ============================================================================
// 2. LOG ANALYTICS WORKSPACE & APPLICATION INSIGHTS (shared)
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-diskreport-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 90
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// ============================================================================
// 3. LINUX FUNCTION APP (Consumption Plan)
// ============================================================================

resource linuxPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: linuxPlanName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

resource linuxFuncApp 'Microsoft.Web/sites@2023-12-01' = {
  name: linuxFuncAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: linuxPlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PowerShell|7.2'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'REPORT_STORAGE_ACCOUNT_NAME'
          value: storageAccount.name
        }
        {
          name: 'REPORT_CONTAINER_NAME'
          value: blobContainerName
        }
      ]
    }
  }
}

// ============================================================================
// 4. WINDOWS FUNCTION APP (Consumption Plan)
// ============================================================================

resource windowsPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: windowsPlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: false
  }
}

resource windowsFuncApp 'Microsoft.Web/sites@2023-12-01' = {
  name: windowsFuncAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: windowsPlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.2'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(windowsFuncAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'REPORT_STORAGE_ACCOUNT_NAME'
          value: storageAccount.name
        }
        {
          name: 'REPORT_CONTAINER_NAME'
          value: blobContainerName
        }
      ]
    }
  }
}

// ============================================================================
// 5. RBAC: Storage Blob Data Contributor (both Function App MSIs)
// ============================================================================

resource blobRoleLinux 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, linuxFuncApp.id, storageBlobContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobContributorRoleId
    principalId: linuxFuncApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobRoleWindows 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, windowsFuncApp.id, storageBlobContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobContributorRoleId
    principalId: windowsFuncApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 6. LOGIC APP (Consumption) — Macro-Orchestrator
// ============================================================================

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('logicapp-workflow.json')
    parameters: {
      linuxFuncAppUrl: {
        value: 'https://${windowsFuncApp.properties.defaultHostName}'
      }
      windowsFuncAppUrl: {
        value: 'https://${windowsFuncApp.properties.defaultHostName}'
      }
      subscriptionId: {
        value: subscription().subscriptionId
      }
    }
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output linuxFuncAppName string = linuxFuncApp.name
output windowsFuncAppName string = windowsFuncApp.name
output linuxFuncPrincipalId string = linuxFuncApp.identity.principalId
output windowsFuncPrincipalId string = windowsFuncApp.identity.principalId
output logicAppPrincipalId string = logicApp.identity.principalId
output storageAccountName string = storageAccount.name
output logicAppName string = logicApp.name
