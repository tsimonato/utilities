<#
.SYNOPSIS
    Run commands in parallel for multiple items (countries/regions), with retry logic.

.DESCRIPTION
    This script generates and executes one batch file per specified item in parallel,
    substituting a placeholder in a command template with each item name. It retries
    failed commands up to a configurable number of times, tracks success/failure,
    and summarizes results.

.PARAMETER RetryCount
    The maximum number of times to retry each command upon failure. Default is 3.

.PARAMETER CommandTemplate
    The command line to execute for each item, containing a placeholder token
    (e.g. {CTRY} by default) that will be replaced by the item name.

.PARAMETER Items
    An array of item identifiers (e.g. country codes or region codes) to process.

.PARAMETER PlaceholderFormat
    (Optional) The placeholder token used in CommandTemplate. Must include curly braces.
    Default is '{CTRY}'. You can set a custom token, e.g. '{REG}'.

.NOTES
    - Creates temporary batch scripts in 'tmp\scripts' and status files in 'tmp\status'.
    - Uses all available CPU cores (NUMBER_OF_PROCESSORS) for parallelism by default.
    - Cleans up old status files on each run.
    - Outputs a color-coded log of initiation, completion, and failures.
    - Commands must be executed in the Windows CMD shell (cmd.exe), not directly in PowerShell.

.EXAMPLE
    # Basic usage with default placeholder {CTRY} and bypass execution policy:
    powershell -ExecutionPolicy Bypass -File "$(GBL)parallel_exec.ps1" -RetryCount 3 `
        -CommandTemplate "wrk\muscale.exe -cmf tmp\{CTRY}_muin.cmf -los dmp/{CTRY}_muin.log <src_muin.sti >NUL:" `
        usa chn jpn

.EXAMPLE
    # Custom placeholder format {REG}, bypass execution policy:
    powershell -ExecutionPolicy Bypass -File "$(GBL)parallel_exec.ps1" -RetryCount 2 `
        -CommandTemplate "wrk\fit.exe -cmf wrk\{REG}_tbb.cmf >dmp\{REG}_tbb.log" `
        -PlaceholderFormat "{REG}" `
        aus usa eu

.EXAMPLE
    # Dry-run mode (simulate without running commands)
    # You can modify the script to add a '-WhatIf' switch to Start-Process for testing.

#>

param (
    [Parameter(Position = 0)]
    [int]$RetryCount = 3,
    
    [Parameter(Position = 1)]
    [string]$CommandTemplate,
    
    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$Items,
    
    [Parameter()]
    [string]$PlaceholderFormat = "{CTRY}"
)

# Start timing execution
$startTime = Get-Date

# Validate parameters
if ([string]::IsNullOrEmpty($CommandTemplate)) {
    Write-Error "Error: Command template is required"
    exit 1
}

if ($Items.Count -eq 0) {
    Write-Error "Error: At least one item must be specified"
    exit 1
}

# Ensure placeholder has proper format with curly braces
if (-not $PlaceholderFormat.StartsWith("{") -or -not $PlaceholderFormat.EndsWith("}")) {
    $PlaceholderFormat = "{$PlaceholderFormat}"
}

# Extract placeholder name for display purposes
$placeholderName = $PlaceholderFormat.Trim('{', '}')
if ([string]::IsNullOrEmpty($placeholderName)) {
    $placeholderName = "ITEM"
    $PlaceholderFormat = "{ITEM}"
}

Write-Host "Processing $($Items.Count) items in parallel using placeholder $PlaceholderFormat..."

# Create temp directories
if (-not (Test-Path -Path "tmp\scripts")) { New-Item -Path "tmp\scripts" -ItemType Directory -Force | Out-Null }
if (-not (Test-Path -Path "tmp\status")) { New-Item -Path "tmp\status" -ItemType Directory -Force | Out-Null }

# Clean old status files
Remove-Item -Path "tmp\status\*" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "tmp\scripts\*.bat" -Force -ErrorAction SilentlyContinue

# Max parallel jobs
$maxThreads = $env:NUMBER_OF_PROCESSORS
if ([string]::IsNullOrEmpty($maxThreads)) { $maxThreads = 4 }

# Status tracking
$runningJobs = @{}
$completedItems = @{}
$failedItems = @{}
$pendingItems = New-Object System.Collections.Queue

# Queue all items
foreach ($item in $Items) {
    $pendingItems.Enqueue($item)
}

# Create batch script for each item
function Create-ItemScript {
    param([string]$item)
    
    $batchPath = "tmp\scripts\$item.bat"
    $escapedPlaceholder = [regex]::Escape($PlaceholderFormat)
    $command = $CommandTemplate -replace $escapedPlaceholder, $item
    
    # Create a batch script that correctly checks the exit code
    @"
@echo off
setlocal EnableDelayedExpansion

set RETRY=0

:retry_loop
$command
set EXIT_CODE=%ERRORLEVEL%
if !EXIT_CODE! NEQ 0 (
    set /a RETRY+=1
    if !RETRY! LSS $RetryCount (
         timeout /t 2 /nobreak >nul
         goto retry_loop
    ) else (
         echo FAILED > tmp\status\$item.failed
         exit /b 1
    )
) else (
    echo SUCCESS > tmp\status\$item.done
    exit /b 0
)
"@ | Set-Content -Path $batchPath -Encoding ASCII
    
    return $batchPath
}

# Process all items in parallel
while ($pendingItems.Count -gt 0 -or $runningJobs.Count -gt 0) {
    # Check for completed jobs
    $completed = @()
    foreach ($item in $runningJobs.Keys) {
        $escapedPlaceholder = [regex]::Escape($PlaceholderFormat)
        $actualCommand = $CommandTemplate -replace $escapedPlaceholder, $item
        
        if (Test-Path -Path "tmp\status\$item.done") {
            $completedItems[$item] = $true
            $completed += $item
            Write-Host "$actualCommand - Completed" -ForegroundColor Green
            try {
                Remove-Item -Path "tmp\status\$item.done" -Force -ErrorAction Stop
            } catch {
                Start-Sleep -Seconds 2
                Remove-Item -Path "tmp\status\$item.done" -Force -ErrorAction SilentlyContinue
            }
        }
        elseif (Test-Path -Path "tmp\status\$item.failed") {
            $failedItems[$item] = $true
            $completed += $item
            Write-Host "$actualCommand - Failed" -ForegroundColor Red
            Remove-Item -Path "tmp\status\$item.failed" -Force
        }
        elseif ($runningJobs[$item].HasExited) {
            # Process ended but no status file was created
            # This generally indicates an unexpected error
            $failedItems[$item] = $true
            $completed += $item
            Write-Host "$actualCommand - Failed (Process exited abnormally)" -ForegroundColor Red
        }
    }
    
    # Remove completed jobs
    foreach ($item in $completed) {
        $job = $runningJobs[$item]
        $runningJobs.Remove($item)
        if ($job -ne $null) {
            Stop-Process -Id $job.Id -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Start new jobs up to max threads
    while ($pendingItems.Count -gt 0 -and $runningJobs.Count -lt $maxThreads) {
        $item = $pendingItems.Dequeue()
        $batchPath = Create-ItemScript -item $item
        
        # Start process
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$batchPath`"" -WindowStyle Hidden -PassThru
        $runningJobs[$item] = $process
        
        $escapedPlaceholder = [regex]::Escape($PlaceholderFormat)
        $actualCommand = $CommandTemplate -replace $escapedPlaceholder, $item
        Write-Host "$actualCommand - Initiated" -ForegroundColor Cyan
    }
    
    # Wait before next check
    if ($pendingItems.Count -gt 0 -or $runningJobs.Count -gt 0) {
        Start-Sleep -Seconds 0.1
    }
}

# Summary
$totalFailed = $failedItems.Count
$totalSuccess = $completedItems.Count
$total = $totalFailed + $totalSuccess
$elapsedTime = (Get-Date) - $startTime
$formattedTime = "{0:hh\:mm\:ss}" -f $elapsedTime

Write-Host "Summary: $totalSuccess successful, $totalFailed failed of $total total (Elapsed time: $formattedTime)`n"

if ($failedItems.Count -gt 0) {
    Write-Host "Failed items: $($failedItems.Keys -join ', ')" -ForegroundColor Red
    exit 1
} else {
    exit 0
}