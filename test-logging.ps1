# Test script to verify logging functionality
Write-Host "Testing log functionality..." -ForegroundColor Green

# Check if log directory exists
$logDir = "$env:LOCALAPPDATA\LiveCaptionsTranslator\logs"
Write-Host "Log directory: $logDir" -ForegroundColor Cyan

if (Test-Path $logDir) {
    Write-Host "Log directory exists!" -ForegroundColor Green
    
    # List all log files
    $logFiles = Get-ChildItem $logDir -Filter "*.txt" | Sort-Object LastWriteTime -Descending
    
    if ($logFiles.Count -gt 0) {
        Write-Host "Found $($logFiles.Count) log files:" -ForegroundColor Yellow
        foreach ($file in $logFiles) {
            Write-Host "  - $($file.Name) (Size: $([math]::Round($file.Length/1KB, 2)) KB, Modified: $($file.LastWriteTime))" -ForegroundColor White
        }
        
        # Show the content of the most recent log file
        $latestLog = $logFiles[0]
        Write-Host "`nContent of latest log file ($($latestLog.Name)):" -ForegroundColor Cyan
        Write-Host "=" * 60 -ForegroundColor Gray
        
        $content = Get-Content $latestLog.FullName -Tail 20
        if ($content) {
            $content | ForEach-Object { Write-Host $_ -ForegroundColor White }
        } else {
            Write-Host "Log file is empty or cannot be read." -ForegroundColor Red
        }
        
        Write-Host "=" * 60 -ForegroundColor Gray
    } else {
        Write-Host "No log files found in the directory." -ForegroundColor Red
    }
} else {
    Write-Host "Log directory does not exist!" -ForegroundColor Red
}

Write-Host "`nNote: Start the application to generate new log entries." -ForegroundColor Magenta