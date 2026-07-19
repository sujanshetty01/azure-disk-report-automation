if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Write-Host "INFO: Authenticated via System-Assigned Managed Identity."
}
else {
    Write-Host "WARN: MSI_SECRET not found. Running in local dev mode."
}
