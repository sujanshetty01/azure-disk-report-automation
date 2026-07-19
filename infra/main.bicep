// ============================================================================
// Azure Storage Cost Remediation Workflow v2 — Main Template
// ============================================================================
// Subscription-scoped entry point.
// Creates the resource group, delegates resource provisioning to the module,
// and assigns RBAC roles at subscription scope.
// ============================================================================

targetScope = 'subscription'

// ─── Parameters ─────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Unique suffix for resource naming.')
@minLength(3)
@maxLength(10)
param nameSuffix string

@description('Resource group name.')
param resourceGroupName string = 'rg-diskreport-${nameSuffix}'

@description('Tags for all resources.')
param tags object = {
  Project: 'DiskReportAutomation'
  ManagedBy: 'Bicep'
}

// ─── Well-Known Role IDs ────────────────────────────────────────────────────

// Virtual Machine Contributor — for Invoke-AzVMRunCommand
var vmContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
)

// Reader — for Logic App Resource Graph queries
var readerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7'
)

// ─── Derived Names for Deterministic GUIDs ────────────────────────────────────

var linuxFuncAppName = 'diskreport-linux-${nameSuffix}'
var windowsFuncAppName = 'diskreport-win-${nameSuffix}'
var logicAppName = 'diskreport-logic-${nameSuffix}'

// ─── Resource Group ─────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ─── Module: All Resources ──────────────────────────────────────────────────

module resources 'main.resources.bicep' = {
  name: 'deploy-diskreport-resources'
  scope: rg
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
  }
}

// ─── RBAC: VM Contributor — Linux Function App MSI (Subscription Scope) ─────

resource vmContributorLinux 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, linuxFuncAppName, vmContributorRoleId)
  properties: {
    roleDefinitionId: vmContributorRoleId
    principalId: resources.outputs.linuxFuncPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Linux Function App MSI — VM Contributor for RunShellScript'
  }
}

// ─── RBAC: VM Contributor — Windows Function App MSI (Subscription Scope) ───

resource vmContributorWindows 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, windowsFuncAppName, vmContributorRoleId)
  properties: {
    roleDefinitionId: vmContributorRoleId
    principalId: resources.outputs.windowsFuncPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Windows Function App MSI — VM Contributor for RunPowerShellScript'
  }
}

// ─── RBAC: Reader — Logic App MSI (Subscription Scope for Resource Graph) ───

resource logicAppReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, logicAppName, readerRoleId)
  properties: {
    roleDefinitionId: readerRoleId
    principalId: resources.outputs.logicAppPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Logic App MSI — Reader for Resource Graph VM/Disk discovery'
  }
}

// ─── Outputs ────────────────────────────────────────────────────────────────

output resourceGroupName string = rg.name
output linuxFuncAppName string = resources.outputs.linuxFuncAppName
output windowsFuncAppName string = resources.outputs.windowsFuncAppName
output storageAccountName string = resources.outputs.storageAccountName
output logicAppName string = resources.outputs.logicAppName
