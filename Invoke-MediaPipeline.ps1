<#
.SYNOPSIS
    Master orchestration script for the complete media conversion and QA pipeline.

.DESCRIPTION
    Automates the entire workflow for video conversion with quality assurance:
    
    PIPELINE STAGES:
    1. Ensure utilities are available (Get-UtilityTools.ps1)
    2. Scan media tree for files to convert (Scan-MediaInfo.ps1)
    3. Execute conversions via HandBrake (Run-HandBrakeCLI.ps1)
    4. Compare source and converted files (Compare-MediaInfo.ps1)
    5. Clean up verified backup files (Clean-HandBrakeBackups.ps1)

    MODES:
    • Standalone: Run the full pipeline manually stage-by-stage
    • Pipeline: Automatically execute all stages with minimal intervention

    Can be run on a single file, folder tree, or resume from a checkpoint.

.PARAMETER SourcePath
    Path to the file or folder to process. For a folder, recursively scans for media files.
    Can be omitted if HandBrakeQueue.csv already exists.

.PARAMETER PipelineRoot
    Working directory for all pipeline operations (default: PSScriptRoot).
    All intermediate files (CSV, JSON, status) are stored here.

.PARAMETER Mode
    Execution mode:
    • 'Full': Runs all stages automatically (scanning → encoding → QA → cleanup)
    • 'Scan': Only scan for media files and generate HandBrakeQueue.csv
    • 'Encode': Only run conversions from existing HandBrakeQueue.csv
    • 'QA': Only run quality assurance comparisons
    • 'Cleanup': Only delete verified backup files
    • 'Interactive': Pause between each stage for user confirmation
    Default: 'Interactive'

.PARAMETER SkipCleanup
    If $true, skip the cleanup stage (keep backup files). Default: $false.

.PARAMETER DryRun
    If $true, preview operations without making changes (applies to cleanup stage).
    Default: $false.

.PARAMETER Force
    If $true, skip confirmation prompts and proceed automatically.
    Default: $false.

.PARAMETER UseLatestTools
    If $true, check vendor websites for latest tool versions before downloading.
    Default: $false (use hardcoded versions).

.PARAMETER QualityLevel
    HandBrake quality setting (0-51). Lower = higher quality. Default: 18.
    Ignored if mode is not 'Full' or 'Encode'.

.PARAMETER UseQSV
    Use Intel QSV hardware acceleration. Default: $true.
    Ignored if mode is not 'Full' or 'Encode'.

.PARAMETER ResumeFrom
    Resume from a specific checkpoint. Options: 'scan', 'encode', 'qa'.
    Default: $null (start from beginning).

.PARAMETER LogFile
    Path to detailed execution log. Default: PipelineRoot\MediaPipeline.log.

.EXIT CODES
    0 - All executed stages completed successfully
    1 - Any stage failed; details in log and console output
    2 - Validation failed (missing tools, invalid parameters, etc.)

.EXAMPLE
    # Full automated pipeline on a folder
    .\Invoke-MediaPipeline.ps1 -SourcePath 'V:\Series\' -Mode Full

    # Interactive mode with prompts between stages
    .\Invoke-MediaPipeline.ps1 -SourcePath 'V:\Series\' -Mode Interactive

    # Scan only
    .\Invoke-MediaPipeline.ps1 -SourcePath 'V:\Series\' -Mode Scan

    # Dry-run cleanup (preview what will be deleted)
    .\Invoke-MediaPipeline.ps1 -Mode Cleanup -DryRun $true

    # Resume encoding from checkpoint
    .\Invoke-MediaPipeline.ps1 -Mode Encode -ResumeFrom encode

    # Download latest tools and run full pipeline
    .\Invoke-MediaPipeline.ps1 -SourcePath 'V:\Films\' -Mode Full -UseLatestTools

    # Single file processing with custom quality
    .\Invoke-MediaPipeline.ps1 -SourcePath 'V:\demo.mp4' -Mode Full -QualityLevel 20
#>
#Requires -Version 7.1

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateScript({ if ($_) { Test-Path $_ } else { $true } })]
    [string]$SourcePath = $null,

    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$PipelineRoot = $PSScriptRoot,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Full', 'Scan', 'Encode', 'QA', 'Cleanup', 'Interactive')]
    [string]$Mode = 'Interactive',

    [Parameter(Mandatory=$false)]
    [bool]$SkipCleanup = $false,

    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $false,

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false,

    [Parameter(Mandatory=$false)]
    [bool]$UseLatestTools = $false,

    [Parameter(Mandatory=$false)]
    [ValidateRange(0, 51)]
    [int]$QualityLevel = 18,

    [Parameter(Mandatory=$false)]
    [bool]$UseQSV = $true,

    [Parameter(Mandatory=$false)]
    [ValidateSet('scan', 'encode', 'qa', $null)]
    [string]$ResumeFrom = $null,

    [Parameter(Mandatory=$false)]
    [string]$LogFile = (Join-Path $PipelineRoot 'MediaPipeline.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =====================================================================
# HELPER FUNCTIONS
# =====================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO',
        [switch]$NoConsole
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    
    if (-not $NoConsole) {
        $color = @{
            'INFO'    = 'Gray'
            'WARN'    = 'Yellow'
            'ERROR'   = 'Red'
            'SUCCESS' = 'Green'
        }
        Write-Host $logEntry -ForegroundColor $color[$Level]
    }
}

function Test-PrerequisitesAvailable {
    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Checking Prerequisites" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $allValid = $true
    
    # Check for required scripts
    $requiredScripts = @(
        'Get-UtilityTools.ps1',
        'Scan-MediaInfo.ps1',
        'Run-HandBrakeCLI.ps1',
        'Compare-MediaInfo.ps1',
        'Clean-HandBrakeBackups.ps1'
    )
    
    foreach ($script in $requiredScripts) {
        $scriptPath = Join-Path $PipelineRoot $script
        if (Test-Path $scriptPath -PathType Leaf) {
            Write-Host "✓ $script" -ForegroundColor Green
            Write-Log "Found required script: $scriptPath"
        }
        else {
            Write-Host "✗ $script (NOT FOUND)" -ForegroundColor Red
            Write-Log "Missing required script: $scriptPath" -Level ERROR
            $allValid = $false
        }
    }
    
    return $allValid
}

function Ensure-UtilitiesInstalled {
    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Ensuring Utilities Are Available" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $getToolsScript = Join-Path $PipelineRoot 'Get-UtilityTools.ps1'
    
    $args = @('-Force', $false)
    if ($UseLatestTools) {
        $args += '-UseLatest', $true
    }
    
    Write-Log "Running Get-UtilityTools.ps1 with arguments: $args"
    
    try {
        & $getToolsScript @args
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Log "Utilities installed successfully" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Get-UtilityTools failed with exit code $exitCode" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Error running Get-UtilityTools: $_" -Level ERROR
        return $false
    }
}

function Invoke-ScanStage {
    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Stage 1: Scan Media Files" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    if (-not $SourcePath) {
        Write-Host "No SourcePath provided. Skipping scan stage." -ForegroundColor Yellow
        Write-Log "Scan stage skipped: no SourcePath provided" -Level WARN
        
        $queuePath = Join-Path $PipelineRoot 'HandBrakeQueue.csv'
        if (Test-Path $queuePath -PathType Leaf) {
            Write-Host "Using existing HandBrakeQueue.csv" -ForegroundColor Gray
            Write-Log "Using existing HandBrakeQueue.csv at $queuePath"
            return $true
        }
        else {
            Write-Host "Error: No SourcePath and no HandBrakeQueue.csv found" -ForegroundColor Red
            Write-Log "Scan stage failed: no SourcePath and no HandBrakeQueue.csv" -Level ERROR
            return $false
        }
    }
    
    $scanScript = Join-Path $PipelineRoot 'Scan-MediaInfo.ps1'
    $mediaInfoPath = Find-UtilityExecutable -ToolName 'MediaInfo'
    
    if (-not $mediaInfoPath) {
        Write-Host "MediaInfo.exe not found. Cannot proceed with scan." -ForegroundColor Red
        Write-Log "MediaInfo.exe not found" -Level ERROR
        return $false
    }
    
    Write-Host "Scanning: $SourcePath" -ForegroundColor Yellow
    Write-Log "Starting scan: $SourcePath with MediaInfo at $mediaInfoPath"
    
    try {
        Push-Location $PipelineRoot
        & $scanScript -RootPath $SourcePath -MediaInfoExe $mediaInfoPath
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        if ($exitCode -eq 0) {
            Write-Log "Scan completed successfully" -Level SUCCESS
            Write-Host "✓ Scan completed successfully" -ForegroundColor Green
            return $true
        }
        else {
            Write-Log "Scan failed with exit code $exitCode" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Scan error: $_" -Level ERROR
        Pop-Location
        return $false
    }
}

function Invoke-EncodeStage {
    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Stage 2: Encode Videos with HandBrake" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $queuePath = Join-Path $PipelineRoot 'HandBrakeQueue.csv'
    
    if (-not (Test-Path $queuePath -PathType Leaf)) {
        Write-Host "HandBrakeQueue.csv not found. Run scan stage first." -ForegroundColor Red
        Write-Log "Encode stage failed: HandBrakeQueue.csv not found at $queuePath" -Level ERROR
        return $false
    }
    
    $handbrakeExe = Find-UtilityExecutable -ToolName 'HandBrake'
    if (-not $handbrakeExe) {
        Write-Host "HandBrakeCLI.exe not found. Cannot proceed with encoding." -ForegroundColor Red
        Write-Log "HandBrakeCLI.exe not found" -Level ERROR
        return $false
    }
    
    $encodeScript = Join-Path $PipelineRoot 'Run-HandBrakeCLI.ps1'
    
    Write-Host "Processing queue from: $queuePath" -ForegroundColor Yellow
    Write-Log "Starting encoding with queue at $queuePath and HandBrake at $handbrakeExe"
    
    try {
        Push-Location $PipelineRoot
        & $encodeScript -CsvPath $queuePath -HandBrakePath $handbrakeExe -QualityLevel $QualityLevel -UseQSV $UseQSV
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        if ($exitCode -eq 0) {
            Write-Log "Encoding completed successfully" -Level SUCCESS
            Write-Host "✓ Encoding completed successfully" -ForegroundColor Green
            return $true
        }
        else {
            Write-Log "Encoding completed with exit code $exitCode" -Level WARN
            # Encoding may have partial successes, don't fail completely
            return $true
        }
    }
    catch {
        Write-Log "Encoding error: $_" -Level ERROR
        Pop-Location
        return $false
    }
}

function Invoke-QAStage {
    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Stage 3: Quality Assurance Comparison" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $conversionsPath = Join-Path $PipelineRoot 'HandBrakeConversions.csv'
    
    if (-not (Test-Path $conversionsPath -PathType Leaf)) {
        Write-Host "HandBrakeConversions.csv not found. Run encoding stage first." -ForegroundColor Red
        Write-Log "QA stage failed: HandBrakeConversions.csv not found at $conversionsPath" -Level ERROR
        return $false
    }
    
    $mediaInfoPath = Find-UtilityExecutable -ToolName 'MediaInfo'
    if (-not $mediaInfoPath) {
        Write-Host "MediaInfo.exe not found. Cannot proceed with QA." -ForegroundColor Red
        Write-Log "MediaInfo.exe not found" -Level ERROR
        return $false
    }
    
    $qaScript = Join-Path $PipelineRoot 'Compare-MediaInfo.ps1'
    
    Write-Host "Comparing conversions from: $conversionsPath" -ForegroundColor Yellow
    Write-Log "Starting QA comparison with conversions at $conversionsPath and MediaInfo at $mediaInfoPath"
    
    try {
        Push-Location $PipelineRoot
        & $qaScript -CsvPath $conversionsPath -MediaInfoExe $mediaInfoPath
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        if ($exitCode -eq 0) {
            Write-Log "QA comparison completed: all passed" -Level SUCCESS
            Write-Host "✓ QA comparison completed: all passed" -ForegroundColor Green
        }
        else {
            Write-Log "QA comparison completed: some failed (exit code $exitCode)" -Level WARN
            Write-Host "⚠️  QA comparison completed: some conversions failed - review ComparisonResult.csv" -ForegroundColor Yellow
        }
        return $true
    }
    catch {
        Write-Log "QA comparison error: $_" -Level ERROR
        Pop-Location
        return $false
    }
}

function Invoke-CleanupStage {
    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Stage 4: Cleanup Backup Files" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $conversionsPath = Join-Path $PipelineRoot 'HandBrakeConversions.csv'
    $comparisonPath = Join-Path $PipelineRoot 'ComparisonResult.csv'
    
    if (-not (Test-Path $conversionsPath -PathType Leaf)) {
        Write-Host "HandBrakeConversions.csv not found. No backups to clean." -ForegroundColor Yellow
        Write-Log "Cleanup stage skipped: HandBrakeConversions.csv not found" -Level WARN
        return $true
    }
    
    $cleanupScript = Join-Path $PipelineRoot 'Clean-HandBrakeBackups.ps1'
    
    $cleanupArgs = @{
        'ConversionsFile' = $conversionsPath
        'DryRun'          = $DryRun
    }
    
    # Use FilterList if available and not dry-run
    if ((Test-Path $comparisonPath -PathType Leaf) -and -not $DryRun) {
        Write-Host "Using ComparisonResult.csv to filter cleanup (only deleting PASSED items)" -ForegroundColor Gray
        $cleanupArgs['FilterList'] = $comparisonPath
    }
    
    if ($Force) {
        $cleanupArgs['Force'] = $true
    }
    
    Write-Host "Cleanup parameters: $(ConvertTo-Json $cleanupArgs)" -ForegroundColor Gray
    Write-Log "Starting cleanup with parameters: $(ConvertTo-Json $cleanupArgs)"
    
    try {
        Push-Location $PipelineRoot
        & $cleanupScript @cleanupArgs
        $exitCode = $LASTEXITCODE
        Pop-Location
        
        if ($exitCode -eq 0) {
            Write-Log "Cleanup completed successfully" -Level SUCCESS
            Write-Host "✓ Cleanup completed successfully" -ForegroundColor Green
            return $true
        }
        else {
            Write-Log "Cleanup completed with exit code $exitCode" -Level WARN
            return $true
        }
    }
    catch {
        Write-Log "Cleanup error: $_" -Level ERROR
        Pop-Location
        return $false
    }
}

function Find-UtilityExecutable {
    param(
        [ValidateSet('MediaInfo', 'HandBrake')]
        [string]$ToolName
    )
    
    $envVarNames = @{
        'MediaInfo' = @('MEDIAINFO_PATH', 'MEDIAINFO_CLI_PATH')
        'HandBrake' = @('HANDBRAKE_CLI_PATH', 'HANDBRAKE_PATH')
    }
    
    $searchNames = @{
        'MediaInfo' = 'MediaInfo.exe'
        'HandBrake' = 'HandBrakeCLI.exe'
    }
    
    $folderPatterns = @{
        'MediaInfo' = 'MediaInfo_CLI_*'
        'HandBrake' = 'HandBrakeCLI-*'
    }
    
    # Check environment variables
    foreach ($envVar in $envVarNames[$ToolName]) {
        $envPath = [Environment]::GetEnvironmentVariable($envVar)
        if ($envPath -and (Test-Path $envPath -PathType Leaf)) {
            return $envPath
        }
    }
    
    # Check in PipelineRoot subdirectories
    $folderMask = $folderPatterns[$ToolName]
    $candidates = Get-ChildItem -Path $PipelineRoot -Directory -Filter $folderMask -ErrorAction SilentlyContinue
    
    foreach ($folder in $candidates) {
        $exePath = Join-Path $folder $searchNames[$ToolName]
        if (Test-Path $exePath -PathType Leaf) {
            return $exePath
        }
    }
    
    # Check PATH
    $pathExe = Get-Command -Name $searchNames[$ToolName] -CommandType Application -ErrorAction SilentlyContinue
    if ($pathExe) {
        return $pathExe.Source
    }
    
    return $null
}

function Show-PipelineMenu {
    Write-Host "`n"
    Write-Host "Select next action:" -ForegroundColor Cyan
    Write-Host "  [S]can media files"
    Write-Host "  [E]ncode videos"
    Write-Host "  [Q]A comparison"
    Write-Host "  [C]leanup backups"
    Write-Host "  [A]ll remaining stages"
    Write-Host "  [X]it"
    
    $choice = Read-Host "Enter choice"
    return $choice.ToUpper()
}

# =====================================================================
# MAIN PIPELINE
# =====================================================================

Write-Host "`n" -NoNewline
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Media Conversion Pipeline" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

Write-Log "Pipeline started in $Mode mode"
Write-Log "SourcePath: $SourcePath"
Write-Log "PipelineRoot: $PipelineRoot"

# Validate prerequisites
if (-not (Test-PrerequisitesAvailable)) {
    Write-Host "`n✗ Prerequisites validation failed" -ForegroundColor Red
    Write-Log "Prerequisites validation failed" -Level ERROR
    exit 2
}

# Ensure utilities
if (-not (Ensure-UtilitiesInstalled)) {
    Write-Host "`n✗ Failed to ensure utilities are installed" -ForegroundColor Red
    Write-Log "Utilities installation failed" -Level ERROR
    exit 2
}

$stagesCompleted = @()
$stageFailed = $false

try {
    if ($Mode -eq 'Full') {
        # Run all stages automatically
        Write-Log "Executing Full mode: all stages"
        
        if (Invoke-ScanStage) { $stagesCompleted += 'Scan' } else { $stageFailed = $true }
        if (Invoke-EncodeStage) { $stagesCompleted += 'Encode' } else { $stageFailed = $true }
        if (Invoke-QAStage) { $stagesCompleted += 'QA' } else { $stageFailed = $true }
        
        if (-not $SkipCleanup) {
            if (Invoke-CleanupStage) { $stagesCompleted += 'Cleanup' } else { $stageFailed = $true }
        }
    }
    elseif ($Mode -eq 'Scan') {
        if (Invoke-ScanStage) { $stagesCompleted += 'Scan' } else { $stageFailed = $true }
    }
    elseif ($Mode -eq 'Encode') {
        if (Invoke-EncodeStage) { $stagesCompleted += 'Encode' } else { $stageFailed = $true }
    }
    elseif ($Mode -eq 'QA') {
        if (Invoke-QAStage) { $stagesCompleted += 'QA' } else { $stageFailed = $true }
    }
    elseif ($Mode -eq 'Cleanup') {
        if (Invoke-CleanupStage) { $stagesCompleted += 'Cleanup' } else { $stageFailed = $true }
    }
    elseif ($Mode -eq 'Interactive') {
        Write-Log "Executing Interactive mode"
        
        $continueLoop = $true
        while ($continueLoop) {
            $choice = Show-PipelineMenu
            
            switch ($choice) {
                'S' {
                    if (Invoke-ScanStage) { $stagesCompleted += 'Scan' }
                    else { $stageFailed = $true; $continueLoop = $false }
                }
                'E' {
                    if (Invoke-EncodeStage) { $stagesCompleted += 'Encode' }
                    else { $stageFailed = $true; $continueLoop = $false }
                }
                'Q' {
                    if (Invoke-QAStage) { $stagesCompleted += 'QA' }
                    else { $stageFailed = $true; $continueLoop = $false }
                }
                'C' {
                    if (Invoke-CleanupStage) { $stagesCompleted += 'Cleanup' }
                    else { $stageFailed = $true; $continueLoop = $false }
                }
                'A' {
                    if ('Scan' -notin $stagesCompleted -and (Invoke-ScanStage)) { $stagesCompleted += 'Scan' }
                    if ('Encode' -notin $stagesCompleted -and (Invoke-EncodeStage)) { $stagesCompleted += 'Encode' }
                    if ('QA' -notin $stagesCompleted -and (Invoke-QAStage)) { $stagesCompleted += 'QA' }
                    if ('Cleanup' -notin $stagesCompleted -and -not $SkipCleanup -and (Invoke-CleanupStage)) { $stagesCompleted += 'Cleanup' }
                    $continueLoop = $false
                }
                'X' {
                    $continueLoop = $false
                }
                default {
                    Write-Host "Invalid choice. Please try again." -ForegroundColor Yellow
                }
            }
        }
    }
}
catch {
    Write-Log "Fatal error in pipeline: $_" -Level ERROR
    Write-Host "`n✗ Pipeline error: $_" -ForegroundColor Red
    $stageFailed = $true
}

# Summary
Write-Host "`n" -NoNewline
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Pipeline Summary" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

if ($stagesCompleted.Count -gt 0) {
    Write-Host "Completed stages: $($stagesCompleted -join ', ')" -ForegroundColor Green
}

if ($stageFailed) {
    Write-Host "Status: FAILED" -ForegroundColor Red
    Write-Log "Pipeline FAILED" -Level ERROR
    Write-Host "Check log for details: $LogFile" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "Status: SUCCESS" -ForegroundColor Green
    Write-Log "Pipeline completed successfully" -Level SUCCESS
    exit 0
}
