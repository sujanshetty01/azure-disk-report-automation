# ============================================================================
# GenerateExcelReport — HTTP-Triggered Excel Report Generator
# ============================================================================
# Receives merged results (Linux + Windows + Unattached disks) from the
# Logic App via HTTP POST. Generates a multi-worksheet .xlsx file using
# the ImportExcel module and uploads it to Azure Blob Storage.
#
# NEW: Leverages Azure Retail Prices API to estimate current disk costs
# (Premium SSD LRS baseline) and calculates potential monthly savings based
# on the recommendation type (Rightsize / Deallocate).
# ============================================================================

using namespace System.Net

param($Request, $TriggerMetadata)

Write-Host "EXCEL-GEN: Starting report generation with Cost Optimization..."

try {
    Import-Module ImportExcel -ErrorAction Stop

    # ─── Fetch Azure Retail Pricing (Premium SSD LRS) ─────────────────────

    Write-Host "EXCEL-GEN: Fetching Azure Retail Pricing..."
    
    # We use a baseline of Premium SSD LRS in East US for cost estimations
    $priceApiUrl = "https://prices.azure.com/api/retail/prices?`$filter=armRegionName eq 'eastus' and serviceFamily eq 'Storage' and productName eq 'Premium SSD Managed Disks'"
    $priceResponse = Invoke-WebRequest -Uri $priceApiUrl -Method Get -UseBasicParsing -ErrorAction SilentlyContinue
    
    $diskPricing = @{}
    if ($priceResponse) {
        $priceData = $priceResponse.Content | ConvertFrom-Json
        foreach ($item in $priceData.Items) {
            # Only get the actual disk cost, not mount or transaction costs
            if ($item.meterName -like "*LRS Disk" -and $item.meterName -notmatch "Mount|Burst") {
                $diskPricing[$item.meterName] = $item.retailPrice
            }
        }
        Write-Host "EXCEL-GEN: Successfully loaded $($diskPricing.Count) disk pricing tiers."
    } else {
        Write-Host "EXCEL-GEN: WARNING - Failed to fetch pricing data. Cost will be 0."
    }

    # Helper function to map GB to Premium SSD Tier and Cost
    function Get-DiskCost {
        param([double]$sizeGB)
        
        $tier = 'P10 LRS Disk' # Default fallback
        if ($sizeGB -le 4) { $tier = 'P1 LRS Disk' }
        elseif ($sizeGB -le 8) { $tier = 'P2 LRS Disk' }
        elseif ($sizeGB -le 16) { $tier = 'P3 LRS Disk' }
        elseif ($sizeGB -le 32) { $tier = 'P4 LRS Disk' }
        elseif ($sizeGB -le 64) { $tier = 'P6 LRS Disk' }
        elseif ($sizeGB -le 128) { $tier = 'P10 LRS Disk' }
        elseif ($sizeGB -le 256) { $tier = 'P15 LRS Disk' }
        elseif ($sizeGB -le 512) { $tier = 'P20 LRS Disk' }
        elseif ($sizeGB -le 1024) { $tier = 'P30 LRS Disk' }
        elseif ($sizeGB -le 2048) { $tier = 'P40 LRS Disk' }
        elseif ($sizeGB -le 4096) { $tier = 'P50 LRS Disk' }
        elseif ($sizeGB -le 8192) { $tier = 'P60 LRS Disk' }
        elseif ($sizeGB -le 16384) { $tier = 'P70 LRS Disk' }
        else { $tier = 'P80 LRS Disk' }

        return [PSCustomObject]@{
            Tier = $tier
            Cost = if ($diskPricing.ContainsKey($tier)) { [math]::Round($diskPricing[$tier], 2) } else { 0.0 }
        }
    }

    # Helper function to process rows and calculate cost savings
    function Process-DiskData {
        param([array]$rawData, [string]$osType)
        $processed = @()
        foreach ($entry in $rawData) {
            $provGB = [math]::Round([double]($entry.ProvisionedGB ?? 0), 2)
            $usedGB = [math]::Round([double]($entry.UsedGB ?? 0), 2)
            $usagePct = [math]::Round([double]($entry.UsagePercent ?? 0), 1)
            $rec = $entry.RecommendationType ?? 'Unknown'
            
            $currentCostInfo = Get-DiskCost -sizeGB $provGB
            $currentCost = $currentCostInfo.Cost
            
            $projectedCost = $currentCost
            if ($rec -eq 'Deallocate' -or $rec -eq 'Wasted (Unattached)') {
                $projectedCost = 0.0
            } elseif ($rec -eq 'Rightsize') {
                # Add 20% buffer to used space for rightsizing target
                $targetGB = $usedGB * 1.2
                $projectedCostInfo = Get-DiskCost -sizeGB $targetGB
                $projectedCost = $projectedCostInfo.Cost
            }

            $savings = [math]::Round(($currentCost - $projectedCost), 2)

            # Build row
            $row = [ordered]@{
                Timestamp            = $timestampStr
                SubscriptionId       = $entry.SubscriptionId ?? 'N/A'
                VMName               = if ($entry.VMName) { $entry.VMName } else { $entry.name ?? 'Unknown' }
                ResourceGroup        = $entry.ResourceGroup ?? 'Unknown'
                Location             = $entry.Location ?? 'Unknown'
                DiskName             = $entry.DiskName ?? 'N/A'
                VmSize               = $entry.VmSize ?? ($entry.sku ?? 'Unknown')
                OsType               = $osType
                DiskIdentifier       = $entry.DiskIdentifier ?? 'N/A'
                ProvisionedGB        = $provGB
                UsedGB               = $usedGB
                UsagePercent         = $usagePct
                RecommendationType   = $rec
                EstimatedCostPerMonth= $currentCost
                ProjectedCostPerMonth= $projectedCost
                MonthlySavings       = $savings
                Status               = $entry.Status ?? 'Unknown'
            }
            $processed += [PSCustomObject]$row
        }
        return $processed
    }

    # ─── Parse Input ─────────────────────────────────────────────────────

    $linuxResults    = $Request.Body.linuxResults    ?? @()
    $windowsResults  = $Request.Body.windowsResults  ?? @()
    $unattachedDisks = $Request.Body.unattachedDisks  ?? @()
    $correlationId   = $Request.Body.correlationId    ?? [guid]::NewGuid().ToString()

    $storageAccountName = $env:REPORT_STORAGE_ACCOUNT_NAME
    $containerName      = $env:REPORT_CONTAINER_NAME ?? 'disk-reports'
    $timestamp          = (Get-Date).ToUniversalTime()
    $timestampStr       = $timestamp.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $blobName           = "azure_vm_disk_usage_$($timestamp.ToString('yyyy-MM-dd_HHmmss')).xlsx"
    $tempPath           = [System.IO.Path]::Combine($env:TEMP, $blobName)

    Write-Host "EXCEL-GEN: Linux=$($linuxResults.Count), Windows=$($windowsResults.Count), Unattached=$($unattachedDisks.Count)"

    # Format Unattached disks to match the schema
    $formattedUnattached = @()
    foreach ($disk in $unattachedDisks) {
        $formattedUnattached += @{
            SubscriptionId     = $disk.subscriptionId
            VMName             = $disk.name
            ResourceGroup      = $disk.resourceGroup
            Location           = $disk.location
            sku                = $disk.sku
            DiskName           = $disk.name
            DiskIdentifier     = 'N/A'
            ProvisionedGB      = $disk.sizeGb
            UsedGB             = $disk.sizeGb
            UsagePercent       = 100.0
            RecommendationType = 'Wasted (Unattached)'
            Status             = 'Success'
        }
    }

    # ─── Process Data with Costs ─────────────────────────────────────────

    $linuxRows = Process-DiskData -rawData $linuxResults -osType 'Linux'
    $windowsRows = Process-DiskData -rawData $windowsResults -osType 'Windows'
    $unattachedRows = Process-DiskData -rawData $formattedUnattached -osType 'Unattached'

    # Calculate Totals
    $totalCurrentCost = ($linuxRows.EstimatedCostPerMonth | Measure-Object -Sum).Sum +
                        ($windowsRows.EstimatedCostPerMonth | Measure-Object -Sum).Sum +
                        ($unattachedRows.EstimatedCostPerMonth | Measure-Object -Sum).Sum

    $totalSavings = ($linuxRows.MonthlySavings | Measure-Object -Sum).Sum +
                    ($windowsRows.MonthlySavings | Measure-Object -Sum).Sum +
                    ($unattachedRows.MonthlySavings | Measure-Object -Sum).Sum

    Write-Host "EXCEL-GEN: Total Current Cost: `$totalCurrentCost | Potential Savings: `$totalSavings"

    # ─── Generate Excel File ─────────────────────────────────────────────

    Write-Host "EXCEL-GEN: Writing Excel to $tempPath..."

    if (Test-Path $tempPath) { Remove-Item $tempPath -Force }

    $excelParams = @{
        AutoSize = $true
        AutoFilter = $true
        FreezeTopRow = $true
        BoldTopRow = $true
        TitleBold = $true
        TitleSize = 14
    }

    if ($linuxRows.Count -gt 0) {
        $linuxRows | Export-Excel -Path $tempPath -WorksheetName 'Linux Disks' @excelParams -Title "Linux VM Disk Usage Report (Est. Savings: `$$(($linuxRows.MonthlySavings | Measure-Object -Sum).Sum))"
    } else {
        [PSCustomObject]@{ Message = 'No Linux VMs found in this scan.' } | Export-Excel -Path $tempPath -WorksheetName 'Linux Disks' -AutoSize
    }

    if ($windowsRows.Count -gt 0) {
        $windowsRows | Export-Excel -Path $tempPath -WorksheetName 'Windows Disks' @excelParams -Title "Windows VM Disk Usage Report (Est. Savings: `$$(($windowsRows.MonthlySavings | Measure-Object -Sum).Sum))"
    } else {
        [PSCustomObject]@{ Message = 'No Windows VMs found in this scan.' } | Export-Excel -Path $tempPath -WorksheetName 'Windows Disks' -AutoSize
    }

    if ($unattachedRows.Count -gt 0) {
        $unattachedRows | Export-Excel -Path $tempPath -WorksheetName 'Unattached Disks' @excelParams -Title "Unattached Managed Disks (Est. Savings: `$$(($unattachedRows.MonthlySavings | Measure-Object -Sum).Sum))"
    } else {
        [PSCustomObject]@{ Message = 'No unattached disks found in this scan.' } | Export-Excel -Path $tempPath -WorksheetName 'Unattached Disks' -AutoSize
    }

    # Summary Sheet
    $summaryData = [ordered]@{
        'Report Date' = $timestampStr
        'Total Disks Scanned' = ($linuxRows.Count + $windowsRows.Count + $unattachedRows.Count)
        'Total Current Monthly Cost' = "`$$([math]::Round($totalCurrentCost, 2))"
        'Total Potential Savings' = "`$$([math]::Round($totalSavings, 2))"
    }
    [PSCustomObject]$summaryData | Export-Excel -Path $tempPath -WorksheetName 'Executive Summary' -AutoSize -Title "Disk Cost Remediation Summary" -TitleBold -TitleSize 16

    # ─── Upload to Blob Storage via REST API ─────────────────────────────

    Write-Host "EXCEL-GEN: Uploading to $storageAccountName/$containerName/$blobName via REST API..."

    # 1. Get Storage Managed Identity Token
    $tokenUrl = "$env:IDENTITY_ENDPOINT`?resource=https://storage.azure.com/&api-version=2019-08-01"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Get -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }
    $storageToken = $tokenResponse.access_token

    # 2. Upload Blob
    $blobUri = "https://$storageAccountName.blob.core.windows.net/$containerName/$blobName"
    $dateString = [DateTime]::UtcNow.ToString("R")
    $headers = @{
        "x-ms-version" = "2020-04-08"
        "x-ms-date" = $dateString
        "x-ms-blob-type" = "BlockBlob"
        "Authorization" = "Bearer $storageToken"
        "Content-Type" = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }

    Invoke-WebRequest -Method Put -Uri $blobUri -Headers $headers -InFile $tempPath -ErrorAction Stop | Out-Null

    if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

    $totalRows = $linuxRows.Count + $windowsRows.Count + $unattachedRows.Count
    Write-Host "EXCEL-GEN: Uploaded $blobUri ($totalRows total rows across 4 sheets)"

    # ─── Return Response ─────────────────────────────────────────────────

    $responseBody = @{
        blobUri            = $blobUri
        blobName           = $blobName
        totalRows          = $totalRows
        totalCurrentCost   = $totalCurrentCost
        totalPotentialSave = $totalSavings
        correlationId      = $correlationId
        generatedAt        = $timestampStr
    } | ConvertTo-Json -Depth 5

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $responseBody
    })
}
catch {
    $errorMsg = $_.Exception.Message
    Write-Host "EXCEL-GEN: FATAL ERROR — $errorMsg"
    Write-Host "EXCEL-GEN: Stack — $($_.ScriptStackTrace)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $errorMsg; correlationId = $correlationId } | ConvertTo-Json)
    })
}
