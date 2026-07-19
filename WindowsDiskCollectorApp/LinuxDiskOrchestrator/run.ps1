# ============================================================================
# LinuxDiskOrchestrator — Fan-Out/Fan-In for Linux VMs
# ============================================================================
# Receives a list of Linux VMs from the Logic App (pre-filtered by OS type).
# Fans out one Activity per VM, collects results, returns aggregated data.
# ============================================================================

param($Context)

$input = $Context.Input | ConvertFrom-Json
$vmList = $input.VmList
$correlationId = $input.CorrelationId

Write-Host "LINUX-ORCH: Starting | VMs=$($vmList.Count) | CorrId=$correlationId"

if (-not $vmList -or $vmList.Count -eq 0) {
    Write-Host "LINUX-ORCH: No Linux VMs received. Returning empty."
    return @{
        osType       = 'Linux'
        results      = @()
        totalVMs     = 0
        successCount = 0
        failedCount  = 0
    }
}

# ─── Fan-Out: One Activity per VM ────────────────────────────────────────

Write-Host "LINUX-ORCH: Fanning out to $($vmList.Count) Linux VM(s)..."

$tasks = @()
foreach ($vm in $vmList) {
    $activityInput = @{
        VMName         = $vm.name
        ResourceGroup  = $vm.resourceGroup
        SubscriptionId = $vm.subscriptionId
        Location       = $vm.location
        VmSize         = $vm.vmSize
        CorrelationId  = $correlationId
    }

    $tasks += Invoke-DurableActivity -FunctionName 'LinuxDiskWorker' -Input $activityInput -NoWait
}

# ─── Fan-In: Wait for All ────────────────────────────────────────────────

Write-Host "LINUX-ORCH: Waiting for $($tasks.Count) activities..."

$allResults = Wait-DurableTask -Task $tasks

# ─── Aggregate ───────────────────────────────────────────────────────────

$flatResults = @()
$successCount = 0
$failedCount = 0

foreach ($result in $allResults) {
    if ($result -is [System.Collections.IEnumerable] -and $result -isnot [string]) {
        foreach ($entry in $result) {
            $flatResults += $entry
            if ($entry.Status -eq 'Success') { $successCount++ } else { $failedCount++ }
        }
    }
    else {
        $flatResults += $result
        if ($result.Status -eq 'Success') { $successCount++ } else { $failedCount++ }
    }
}

Write-Host "LINUX-ORCH: Done | OK=$successCount, Fail=$failedCount, Entries=$($flatResults.Count)"

return @{
    osType       = 'Linux'
    results      = $flatResults
    totalVMs     = $vmList.Count
    successCount = $successCount
    failedCount  = $failedCount
}
