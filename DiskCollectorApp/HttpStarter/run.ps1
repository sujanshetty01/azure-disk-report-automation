using namespace System.Net

param($Request, $TriggerMetadata)

$functionName = $Request.Params.functionName

$orchestratorInput = @{
    VmList        = $Request.Body.vmList
    CorrelationId = $Request.Body.correlationId ?? [guid]::NewGuid().ToString()
    Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 10

Write-Host "WINDOWS-STARTER: Starting '$functionName' | VMs=$($Request.Body.vmList.Count)"

$instanceId = Start-DurableOrchestration -FunctionName $functionName -Input $orchestratorInput
Write-Host "WINDOWS-STARTER: Instance '$instanceId' started."

$response = New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $instanceId
Push-OutputBinding -Name Response -Value $response
