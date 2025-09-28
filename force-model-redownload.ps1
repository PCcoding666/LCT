# Script to force model re-download for testing logging
Write-Host "Force Model Re-download Test Script" -ForegroundColor Green
Write-Host "This will remove the existing model to test download logging" -ForegroundColor Yellow

$modelsPath = "$env:LOCALAPPDATA\LiveCaptionsTranslator\models"

Write-Host "`nModel storage path: $modelsPath" -ForegroundColor Cyan

if (Test-Path $modelsPath) {
    Write-Host "Models directory exists. Contents:" -ForegroundColor White
    try {
        Get-ChildItem $modelsPath -Recurse | ForEach-Object {
            if ($_.PSIsContainer) {
                Write-Host "  [DIR]  $($_.FullName)" -ForegroundColor Blue
            } else {
                Write-Host "  [FILE] $($_.FullName) ($([math]::Round($_.Length/1MB, 2)) MB)" -ForegroundColor Gray
            }
        }
        
        $choice = Read-Host "`nDo you want to remove the models directory to force re-download? (y/N)"
        if ($choice -eq "y" -or $choice -eq "Y") {
            Write-Host "Removing models directory..." -ForegroundColor Red
            Remove-Item $modelsPath -Recurse -Force
            Write-Host "Models directory removed. Next app startup will trigger model download." -ForegroundColor Green
        } else {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Error accessing models directory: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "Models directory does not exist. Model download will be triggered on next startup." -ForegroundColor Green
}

Write-Host "`nNote: After removing models, start the application to see download progress in logs." -ForegroundColor Magenta
Write-Host "You can monitor logs in real-time using:" -ForegroundColor Cyan
Write-Host "  Get-Content '$env:LOCALAPPDATA\LiveCaptionsTranslator\logs\log-$(Get-Date -Format 'yyyyMMdd').txt' -Wait" -ForegroundColor White