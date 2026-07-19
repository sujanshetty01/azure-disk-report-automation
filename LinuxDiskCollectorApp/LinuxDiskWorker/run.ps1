# ============================================================================
# LinuxDiskWorker — Activity Function for a Single Linux VM
# ============================================================================
# Executes Invoke-AzVMRunCommand with RunShellScript (df -P -B1) on a single
# Linux VM. Parses the output and computes recommendation type.
#
# ERROR HANDLING: Wrapped in try/catch. Returns Status=Failed on any error
# so the Fan-In never crashes.
# ============================================================================

param($Input)

$payload = $Input
if ($Input -is [string]) {
    try { $payload = $Input | ConvertFrom-Json } catch {}
}

$vmName         = $payload.VMName
$rg             = $payload.ResourceGroup
$subscriptionId = $payload.SubscriptionId
$location       = $payload.Location
$vmSize         = $payload.VmSize

Write-Host "LINUX-WORKER: VM='$vmName' | RG='$rg' | Sub='$subscriptionId'"

try {
    # Set subscription context if provided
    if ($subscriptionId) {
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    }

    # ─── Execute RunShellScript ──────────────────────────────────────────

    $linuxScript = @'
df -P -B1 --exclude-type=tmpfs --exclude-type=devtmpfs --exclude-type=squashfs --exclude-type=overlay 2>/dev/null | tail -n +2 | awk '{
    totalGB = $2 / 1073741824
    usedGB  = $3 / 1073741824
    freeGB  = $4 / 1073741824
    pct     = (totalGB > 0) ? (usedGB / totalGB) * 100 : 0
    printf "%s|%.2f|%.2f|%.2f|%.1f\n", $6, usedGB, totalGB, freeGB, pct
}'
'@

    Write-Host "LINUX-WORKER: Executing RunShellScript on '$vmName'..."

    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $rg `
        -VMName $vmName `
        -CommandId 'RunShellScript' `
        -ScriptString $linuxScript `
        -ErrorAction Stop

    $output = $result.Value |
        Where-Object { $_.Code -eq 'ComponentStatus/StdOut/succeeded' } |
        Select-Object -ExpandProperty Message

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
