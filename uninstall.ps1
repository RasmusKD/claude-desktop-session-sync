# Removes the ClaudeChatSync scheduled task and the hidden launcher.
# Your chat files are left exactly as they are (the sync never owned them).
$ErrorActionPreference = 'Stop'

$taskName = 'ClaudeChatSync'
$vbs      = Join-Path $PSScriptRoot 'sync-hidden.vbs'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Scheduled task '$taskName' removed." -ForegroundColor Green
} else {
    Write-Host "No '$taskName' task found - nothing to remove."
}

if (Test-Path $vbs) { Remove-Item $vbs; Write-Host "Launcher removed." }

Write-Host "Done. Chat files were not touched. Each account now keeps its own list going forward."
