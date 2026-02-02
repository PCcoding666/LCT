# Clean old model and force download new one
Write-Host "Cleaning old qwen2.5:3b model and forcing download of qwen3:4b-instruct-2507-q4_K_M..." -ForegroundColor Green

try {
    # Stop Ollama processes
    Write-Host "Stopping Ollama processes..." -ForegroundColor Yellow
    Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    
    # Remove old model
    Write-Host "Removing old model qwen2.5:3b..." -ForegroundColor Yellow
    & ollama rm qwen2.5:3b
    
    # Pull new model
    Write-Host "Downloading new model qwen3:4b-instruct-2507-q4_K_M..." -ForegroundColor Yellow
    & ollama pull qwen3:4b-instruct-2507-q4_K_M
    
    Write-Host "Model cleanup and download completed!" -ForegroundColor Green
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")