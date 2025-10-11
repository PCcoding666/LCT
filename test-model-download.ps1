# Test model download and progress display
Write-Host "Testing Model Download and Progress Display..." -ForegroundColor Green

try {
    # Stop existing Ollama processes
    Write-Host "Stopping existing Ollama processes..." -ForegroundColor Yellow
    Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    
    # Remove current model to trigger download
    Write-Host "Removing current model to trigger download..." -ForegroundColor Yellow
    & ollama rm qwen3:4b-instruct-2507-q4_K_M 2>$null
    & ollama rm qwen2.5:3b 2>$null
    
    Write-Host "Starting application to test enhanced download progress..." -ForegroundColor Green
    Write-Host "Expected improvements:" -ForegroundColor Cyan
    Write-Host "  1. Resizable splash window" -ForegroundColor White
    Write-Host "  2. Enhanced model download progress bar" -ForegroundColor White
    Write-Host "  3. Better model existence checking" -ForegroundColor White
    Write-Host "  4. More detailed logging in scrollable area" -ForegroundColor White
    Write-Host ""
    Write-Host "The application should now download qwen3:4b-instruct-2507-q4_K_M with visual progress..." -ForegroundColor Green
    
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")