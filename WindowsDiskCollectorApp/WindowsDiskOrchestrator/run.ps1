# ============================================================================
# WindowsDiskOrchestrator — Fan-Out/Fan-In for Windows VMs
# ============================================================================
# Receives a list of Windows VMs from the Logic App (pre-filtered by OS type).
# Fans out one Activity per VM, collects results, returns aggregated data.
# ============================================================================

param($Context)

$input = $Context.Input | ConvertFrom-Json
$vmList = $input.VmList
$correlationId = $input.CorrelationId

Write-Host "WIN-ORCH: Starting | VMs=$($vmList.Count) | CorrId=$correlationId"

if (-not $vmList -or $vmList.Count -eq 0) {
    Write-Host "WIN-ORCH: No Windows VMs received. Returning empty."
    return @{
        osType       = 'Windows'
        results      = @()
        totalVMs     = 0
        successCount = 0
        failedCount  = 0
    }
}

# ─── Fan-Out: One Activity per VM ────────────────────────────────────────

Write-Host "WIN-ORCH: Fanning out to $($vmList.Count) Windows VM(s)..."

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

    $tasks += Invoke-DurableActivity -FunctionName 'WindowsDiskWorker' -Input $activityInput -NoWait
}

# ─── Fan-In: Wait for All ────────────────────────────────────────────────

Write-Host "WIN-ORCH: Waiting for $($tasks.Count) activities..."

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

Write-Host "WIN-ORCH: Done | OK=$successCount, Fail=$failedCount, Entries=$($flatResults.Count)"

return @{
    osType       = 'Windows'
    results      = $flatResults
    totalVMs     = $vmList.Count
    successCount = $successCount
    failedCount  = $failedCount
}
