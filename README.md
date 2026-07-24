# Azure VM Disk Report Automation

This project automatically scans an entire Azure subscription for all running Virtual Machines (both Windows and Linux) and unattached disks, executes native disk usage scripts using Azure's Management API, calculates potential cost savings, and compiles everything into a consolidated, multi-tabbed Excel report that is uploaded to Azure Blob Storage.

## Features

- **Blazing Fast Fan-Out:** Uses Azure Durable Functions to fan out disk metric collection to hundreds of VMs simultaneously. The entire subscription scan executes in under 20 seconds.
- **Native Azure API Integration:** Uses the Azure Control Plane (REST APIs) rather than unstable `Invoke-AzVMRunCommand` Cmdlets to prevent crashes and ensure reliability.
- **Cost Optimization Analytics:** Dynamically pulls the latest Microsoft Retail Pricing API rates to calculate your monthly cost and potential savings based on rightsizing (adding a 20% buffer to used space) or deallocating wasted resources.
- **Automated Workflow:** Controlled by an Azure Logic App on a weekly schedule.
- **Excel Generation:** Exports natively formatted Excel Workbooks with tabs for Windows, Linux, and Unattached Disks, complete with formulas and executive summaries.

## Architecture

The project is built on two main components:

1. **Azure Logic App**: Orchestrates the entire workflow. It uses Azure Resource Graph to discover all running Windows and Linux VMs, and unattached disks. It triggers the respective Durable Function Orchestrators and passes the output to the Excel generator.
2. **DiskCollectorApp**: A PowerShell-based Azure Function App. It orchestrates the asynchronous execution of `df -h` on Linux VMs and `Get-Volume` on Windows VMs using the Azure REST API and calculates space/usage metrics. It also hosts the `GenerateExcelReport` function which leverages the `ImportExcel` module to compile the final `.xlsx` file.

## Setup Instructions

### 1. Deploy Infrastructure

The entire infrastructure can be deployed in a single command using Bicep.

```bash
cd infra
az deployment sub create --name "DiskReportDeployment" --location eastus --template-file main.bicep --parameters nameSuffix="prod01"
```

This will deploy:
- Resource Group
- Storage Account
- App Insights & Log Analytics Workspace
- Function App and App Service Plan
- Azure Logic App
- Managed Identities with proper RBAC assignments (Contributor on subscription).

### 2. Deploy Azure Functions Code

You can deploy the code directly to the created Function App.

```powershell
cd DiskCollectorApp
Compress-Archive -Path * -DestinationPath app.zip -Force
az functionapp deployment source config-zip -g "rg-diskreport-prod01" -n "diskreport-func-prod01" --src app.zip
```

### 3. Setup Complete

Once deployed, you can navigate to your Azure Logic App and click **Run Trigger** to test the workflow.
The final report will be uploaded to the `disk-reports` container inside the generated Storage Account.
