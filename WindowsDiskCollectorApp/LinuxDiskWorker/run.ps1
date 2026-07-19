# ============================================================================
# LinuxDiskWorker — Activity Function for a Single Linux VM
# ============================================================================
# Executes Invoke-AzVMRunCommand with RunShellScript (df -P -B1) on a single
# Linux VM. Parses the output and computes recommendation type.
#
# ERROR HANDLING: Wrapped in try/catch. Returns Status=Failed on any error
# so the Fan-In never crashes.
# ============================================================================

param($name)

$payload = $name

$vmName         = $payload.VMName
$rg             = $payload.ResourceGroup
$subscriptionId = $payload.SubscriptionId
$location       = $payload.Location
$vmSize         = $payload.VmSize

Write-Host "LINUX-WORKER: VM='$vmName' | RG='$rg' | Sub='$subscriptionId'"

try {
    # ─── Execute RunShellScript via REST API ─────────────────────────────
    
    # 1. Get Managed Identity Token
    $tokenUrl = "$env:IDENTITY_ENDPOINT`?resource=https://management.azure.com/&api-version=2019-08-01"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Get -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }
    $accessToken = $tokenResponse.access_token

    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
    }

    # 2. Start RunCommand
    $runCmdUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$vmName/runCommand?api-version=2024-03-01"
    $scriptLines = @(
        "df -P -B1 --exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=squashfs --exclude-type=overlay 2>/dev/null | tail -n +2 | awk '{",
        "    totalGB = `$2 / 1073741824",
        "    usedGB  = `$3 / 1073741824",
        "    freeGB  = `$4 / 1073741824",
        "    pct     = (totalGB > 0) ? (usedGB / totalGB) * 100 : 0",
        "    printf `"`%s|`%.2f|`%.2f|`%.2f|`%.1f\n`", `$6, usedGB, totalGB, freeGB, pct",
        "}'"
    )
    $body = @{
        commandId = "RunShellScript"
        script = $scriptLines
    } | ConvertTo-Json -Depth 5

    Write-Host "LINUX-WORKER: Executing RunShellScript REST API on '$vmName'..."
    
    $initialResponse = Invoke-WebRequest -Method Post -Uri $runCmdUrl -Headers $headers -Body $body -ErrorAction Stop -UseBasicParsing

    # 3. Poll for Completion
    $asyncUrl = $initialResponse.Headers["Location"] | Select-Object -First 1
    if (-not $asyncUrl) {
        $asyncUrl = $initialResponse.Headers["Azure-AsyncOperation"] | Select-Object -First 1
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
        Write-Host "LINUX-WORKER: WARNING — Empty output from '$vmName'."
        return @(@{
            VMName             = $vmName
            ResourceGroup      = $rg
            SubscriptionId     = $subscriptionId
            Location           = $location
            VmSize             = $vmSize
            OsType             = 'Linux'
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

    # ─── Parse Output ────────────────────────────────────────────────────

    $diskEntries = @()
    $lines = $output.Trim().Split("`n", [System.StringSplitOptions]::RemoveEmptyEntries)

    foreach ($line in $lines) {
        $parts = $line.Trim().Split('|')
        if ($parts.Count -ge 5) {
            $usedGB   = [double]$parts[1].Trim()
            $totalGB  = [double]$parts[2].Trim()
            $freeGB   = [double]$parts[3].Trim()
            $pct      = [double]$parts[4].Trim()

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
                DiskIdentifier     = $parts[0].Trim()
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

    Write-Host "LINUX-WORKER: FAILED '$vmName' — $errorMsg"

    return @(@{
        VMName             = $vmName
        ResourceGroup      = $rg
        SubscriptionId     = $subscriptionId
        Location           = $location
        VmSize             = $vmSize
        OsType             = 'Linux'
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
