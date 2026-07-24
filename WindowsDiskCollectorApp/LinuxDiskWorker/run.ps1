# ============================================================================
# LinuxDiskWorker - Collects disk usage for a single Linux VM using REST API
# ============================================================================

param($name)

$payload = $name
if ($name -is [string]) {
    try { $payload = $name | ConvertFrom-Json } catch {}
}

$vmName         = $payload.VMName
$rg             = $payload.ResourceGroup
$subscriptionId = $payload.SubscriptionId
$location       = $payload.Location
$vmSize         = $payload.VmSize

Write-Host "LINUX-WORKER: VM='$vmName' | RG='$rg' | Sub='$subscriptionId'"

try {
    # 1. Get Access Token for REST APIs
    $tokenUrl = "$env:IDENTITY_ENDPOINT" + "?resource=https://management.azure.com/&api-version=2019-08-01"
    $tokenResponse = Invoke-RestMethod -Method Get -Uri $tokenUrl -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }
    $token = $tokenResponse.access_token

    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    # 2. Fetch VM storage profile to get Azure managed disk names
    $vmUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/${vmName}?api-version=2024-03-01"
    $vmDetails = Invoke-RestMethod -Method Get -Uri $vmUrl -Headers $headers -ErrorAction SilentlyContinue

    $osDiskName = if ($vmDetails.properties.storageProfile.osDisk.name) { $vmDetails.properties.storageProfile.osDisk.name } else { 'Unknown' }
    $dataDiskNames = @($vmDetails.properties.storageProfile.dataDisks | Sort-Object lun | ForEach-Object { $_.name })

    # 3. Start RunCommand
    $runCmdUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/${vmName}/runCommand?api-version=2024-03-01"
    
    $linuxScript = @"
df -P -B1 2>/dev/null | tail -n +2 | awk '{
    if (`$1 ~ /^\/dev\// || `$1 ~ /^overlay/) {
        totalGB = `$2 / 1073741824
        usedGB  = `$3 / 1073741824
        freeGB  = `$4 / 1073741824
        pct     = (totalGB > 0) ? (usedGB / totalGB) * 100 : 0
        printf "%s|%s|%.2f|%.2f|%.2f|%.1f\n", `$1, `$6, usedGB, totalGB, freeGB, pct
    }
}'
"@
    
    $body = @{
        commandId = "RunShellScript"
        script = @($linuxScript)
    } | ConvertTo-Json -Depth 5

    Write-Host "LINUX-WORKER: Executing RunShellScript REST API on '$vmName'..."
    
    $initialResponse = Invoke-WebRequest -Method Post -Uri $runCmdUrl -Headers $headers -Body $body -ErrorAction Stop -UseBasicParsing

    # 4. Poll for Completion
    $asyncUrl = $null
    foreach ($key in $initialResponse.Headers.Keys) {
        if ($key -match '^Location$') {
            $val = $initialResponse.Headers[$key]
            if ($val -is [array]) { $asyncUrl = $val[0] } else { $asyncUrl = $val }
            break
        }
    }
    if (-not $asyncUrl) {
        foreach ($key in $initialResponse.Headers.Keys) {
            if ($key -match '^Azure-AsyncOperation$') {
                $val = $initialResponse.Headers[$key]
                if ($val -is [array]) { $asyncUrl = $val[0] } else { $asyncUrl = $val }
                break
            }
        }
    }

    $status = "InProgress"
    $pollCount = 0
    $finalJson = $null
    while ($status -eq "InProgress" -and $pollCount -lt 60) {
        Start-Sleep -Seconds 5
        $pollCount++
        $pollResponse = Invoke-WebRequest -Method Get -Uri $asyncUrl -Headers $headers -ErrorAction Stop -UseBasicParsing
        if ($pollResponse.StatusCode -eq 202) {
            $status = "InProgress"
        } elseif ($pollResponse.StatusCode -eq 200) {
            if (-not [string]::IsNullOrWhiteSpace($pollResponse.Content)) {
                $finalJson = $pollResponse.Content | ConvertFrom-Json
                if ($finalJson.status) {
                    $status = $finalJson.status
                } else {
                    $status = "Succeeded"
                }
            } else {
                $status = "Succeeded"
            }
        } else {
            throw "Unexpected polling status code: $($pollResponse.StatusCode)"
        }
    }

    if ($status -ne "Succeeded") {
        throw "RunCommand failed or timed out. Status: $status"
    }

    $output = ""
    if ($finalJson -and $finalJson.value) {
        $msgObj = $finalJson.value | Where-Object { $_.code -like '*succeeded*' }
        if ($msgObj) {
            $msg = $msgObj.message
            if ($msg -match '\[stdout\]\s*(?s)(.*?)\s*\[stderr\]') {
                $output = $matches[1]
            } else {
                $output = $msg
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        Write-Host "LINUX-WORKER: WARNING - Empty output from '$vmName'."
        return @(@{
            VMName             = $vmName
            ResourceGroup      = $rg
            SubscriptionId     = $subscriptionId
            Location           = $location
            VmSize             = $vmSize
            OsType             = 'Linux'
            DiskName           = 'N/A'
            DiskIdentifier     = 'N/A'
            UsedGB             = 0
            ProvisionedGB      = 0
            FreeGB             = 0
            UsagePercent       = 0
            RecommendationType = 'Unknown'
            Status             = 'Failed'
            ErrorMessage       = 'Empty output from Run Command'
        })
    }

    # 5. Parse Output
    $diskEntries = @()
    $lines = $output.Trim().Split("`n", [System.StringSplitOptions]::RemoveEmptyEntries)

    $dataDiskMap = @{}
    $dataDiskCounter = 0

    foreach ($line in $lines) {
        $parts = $line.Trim().Split('|')
        if ($parts.Count -ge 6) {
            $blockDev = $parts[0].Trim()
            $mountPt  = $parts[1].Trim()
            $usedGB   = [double]$parts[2].Trim()
            $totalGB  = [double]$parts[3].Trim()
            $freeGB   = [double]$parts[4].Trim()
            $pct      = [double]$parts[5].Trim()

            # Extract base device (e.g., /dev/sda1 -> /dev/sda, /dev/nvme0n1p1 -> /dev/nvme0n1)
            $baseDev = $blockDev -replace '\d+$', ''
            $baseDev = $baseDev -replace 'p$', ''

            # Map block device to Azure disk name
            if ($baseDev -match '/dev/sda|/dev/root|/dev/nvme0n1|overlay') {
                $azureDiskName = $osDiskName
            } elseif ($baseDev -match '/dev/sdb|/dev/nvme0n2') {
                $azureDiskName = 'Temporary Resource Disk'
            } elseif ($baseDev -match '/dev/sd[c-z]|/dev/nvme0n[3-9]') {
                if (-not $dataDiskMap.ContainsKey($baseDev)) {
                    if ($dataDiskCounter -lt $dataDiskNames.Count) {
                        $dataDiskMap[$baseDev] = $dataDiskNames[$dataDiskCounter]
                        $dataDiskCounter++
                    } else {
                        $dataDiskMap[$baseDev] = "Data Disk (Unmapped $baseDev)"
                    }
                }
                $azureDiskName = $dataDiskMap[$baseDev]
            } else {
                $azureDiskName = $osDiskName 
            }

            # Recommendation logic
            $recommendation = if ($pct -lt 5) { 'Deallocate' }
                              elseif ($pct -lt 20) { 'Rightsize' }
                              else { 'No Action' }

            $diskEntries += @{
                VMName             = $vmName
                ResourceGroup      = $rg
                SubscriptionId     = $subscriptionId
                Location           = $location
                VmSize             = $vmSize
                OsType             = 'Linux'
                DiskName           = $azureDiskName
                DiskIdentifier     = $mountPt
                UsedGB             = $usedGB
                ProvisionedGB      = $totalGB
                FreeGB             = $freeGB
                UsagePercent       = $pct
                RecommendationType = $recommendation
                Status             = 'Success'
                ErrorMessage       = ''
            }
        }
    }

    Write-Host "LINUX-WORKER: '$vmName' returned $($diskEntries.Count) mount point(s)."
    return $diskEntries
}
catch {
    $errorMsg = $_.Exception.Message
    if ($_.ErrorDetails) {
        $errorMsg = "$errorMsg | Body: $($_.ErrorDetails.Message)"
    }

    Write-Host "LINUX-WORKER: FAILED '$vmName' - $errorMsg"

    return @(@{
        VMName             = $vmName
        ResourceGroup      = $rg
        SubscriptionId     = $subscriptionId
        Location           = $location
        VmSize             = $vmSize
        OsType             = 'Linux'
        DiskName           = 'N/A'
        DiskIdentifier     = 'N/A'
        UsedGB             = 0
        ProvisionedGB      = 0
        FreeGB             = 0
        UsagePercent       = 0
        RecommendationType = 'Unknown'
        Status             = 'Failed'
        ErrorMessage       = $errorMsg
    })
}
