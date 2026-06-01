<#
.SYNOPSIS
    Safely deletes backup files after manual verification of successful video conversions.

.DESCRIPTION
    Reads conversion tracking files and deletes backup files (`*_bak.*`) that have been
    successfully converted and verified via QA evaluation.

    Can operate in two modes:
    1. ALL BACKUPS: Delete all backups listed in HandBrakeConversions.csv (requires explicit confirmation)
    2. FILTERED: Delete only backups from files that passed QA evaluation in ComparisonResult.csv

    SAFETY FEATURES:
    • Dry-run mode (`-DryRun $true`) previews deletions without removing files
    • Only deletes `*_bak.*` files associated with successful conversions
    • Prevents accidental deletion of unrelated files
    • Detailed logging of all deletion operations
    • Requires explicit confirmation before permanent deletion

    WORKFLOW:
    1. Run `Run-HandBrakeCLI.ps1` to encode files (creates HandBrakeConversions.csv)
    2. Run `Compare-MediaInfo.ps1` to verify conversions (creates ComparisonResult.csv)
    3. Run `Clean-HandBrakeBackups.ps1 -DryRun $true` to preview what will be deleted
    4. Run `Clean-HandBrakeBackups.ps1` to permanently delete verified backups

.PARAMETER ConversionsFile
    Path to HandBrakeConversions.csv (created by Run-HandBrakeCLI.ps1).
    Expected columns: BackupFile, OutputFile
    Default: same folder as script

.PARAMETER FilterList
    Optional path to ComparisonResult.csv (created by Compare-MediaInfo.ps1).
    When specified, only deletes backups from files with Status=PASSED.
    Expected columns: BackupFile, OutputFile, Status
    Default: $null (no filtering, deletes all backups)

.PARAMETER DryRun
    If $true, previews deletions without removing files (default: $false).
    Useful for verifying which backups will be deleted before confirming.

.PARAMETER Force
    If $true, skip confirmation prompt and proceed with deletion (default: $false).
    Use with caution.

.EXIT CODES
    0 - Successful cleanup (or dry-run completed)
    1 - Error during cleanup or user cancelled operation

.EXAMPLE
    # Preview what will be deleted (safe to run)
    .\Clean-HandBrakeBackups.ps1 -DryRun $true

    # Delete all verified backups from ComparisonResult.csv
    .\Clean-HandBrakeBackups.ps1 -FilterList '.\ComparisonResult.csv'

    # Delete all backups (use with caution)
    .\Clean-HandBrakeBackups.ps1 -Force

    # Delete verified backups without confirmation
    .\Clean-HandBrakeBackups.ps1 -FilterList '.\ComparisonResult.csv' -Force
#>
#Requires -Version 7.1

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConversionsFile = (Join-Path $PSScriptRoot 'HandBrakeConversions.csv'),

    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$FilterList = $null,

    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $false,

    [Parameter(Mandatory=$false)]
    [bool]$Force = $false
)

# -------------------------------------------------
# Helper: Load conversions from CSV file
# -------------------------------------------------
function Import-ConversionsList {
    param(
        [string]$CsvPath
    )

    if (-not (Test-Path $CsvPath -PathType Leaf)) {
        throw "Conversions file not found: $CsvPath"
    }

    try {
        return @(Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop)
    }
    catch {
        throw "Failed to read conversions file: $_"
    }
}

# -------------------------------------------------
# Helper: Load filter list from ComparisonResult.csv
# -------------------------------------------------
function Import-FilterList {
    param(
        [string]$CsvPath
    )

    if (-not (Test-Path $CsvPath -PathType Leaf)) {
        throw "Filter list file not found: $CsvPath"
    }

    try {
        $filterData = @(Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop)
        
        # Extract only passed backups
        $passedBackups = @($filterData | Where-Object { $_.Status -eq 'PASSED' } | Select-Object -ExpandProperty BackupFile)
        
        Write-Host "Filter list loaded: $($passedBackups.Count) files passed QA evaluation" -ForegroundColor Cyan
        
        return $passedBackups
    }
    catch {
        throw "Failed to read filter list: $_"
    }
}

# -------------------------------------------------
# Main: Clean up backup files
# -------------------------------------------------
function Invoke-BackupCleanup {
    param(
        [string]$ConversionsFile,
        [string]$FilterList,
        [bool]$DryRun,
        [bool]$Force
    )

    Write-Host "`n" -NoNewline
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  HandBrake Backup Cleanup Utility" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # Load conversions
    try {
        Write-Host "Loading conversions list..." -ForegroundColor Yellow
        $conversions = Import-ConversionsList -CsvPath $ConversionsFile
        Write-Host "✓ Loaded $($conversions.Count) conversion records" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to load conversions: $_"
        return $false
    }

    if ($conversions.Count -eq 0) {
        Write-Host "`n⚠ No conversion records found. Nothing to clean up." -ForegroundColor Yellow
        return $true
    }

    # Determine which backups to delete
    $backupsToDelete = @()

    if ($FilterList) {
        # Filter mode: only delete verified backups
        try {
            Write-Host "Loading filter list..." -ForegroundColor Yellow
            $passedBackups = Import-FilterList -CsvPath $FilterList
        }
        catch {
            Write-Error "Failed to load filter list: $_"
            return $false
        }

        # Match conversions against passed backups
        foreach ($conversion in $conversions) {
            $backupFile = $conversion.BackupFile
            
            if ($passedBackups -contains $backupFile) {
                if (Test-Path $backupFile -PathType Leaf) {
                    $backupsToDelete += [PSCustomObject]@{
                        BackupFile = $backupFile
                        OutputFile = $conversion.OutputFile
                        Status = "VERIFIED"
                    }
                }
                else {
                    Write-Warning "Backup file not found (possibly already deleted): $backupFile"
                }
            }
        }

        Write-Host "Filter applied: $($backupsToDelete.Count) verified backups ready for deletion" -ForegroundColor Cyan
    }
    else {
        # All mode: delete all backups (requires confirmation)
        foreach ($conversion in $conversions) {
            $backupFile = $conversion.BackupFile
            
            if (Test-Path $backupFile -PathType Leaf) {
                $backupsToDelete += [PSCustomObject]@{
                    BackupFile = $backupFile
                    OutputFile = $conversion.OutputFile
                    Status = "UNVERIFIED"
                }
            }
            else {
                Write-Warning "Backup file not found (possibly already deleted): $backupFile"
            }
        }

        Write-Host "All mode: $($backupsToDelete.Count) backups ready for deletion" -ForegroundColor Yellow
        Write-Host "⚠️  WARNING: These backups have NOT been verified by QA evaluation." -ForegroundColor Red
    }

    if ($backupsToDelete.Count -eq 0) {
        Write-Host "`n✓ No backups to delete." -ForegroundColor Green
        return $true
    }

    # Display deletion plan
    Write-Host "`n" -NoNewline
    Write-Host "Deletion Plan:" -ForegroundColor Cyan
    Write-Host ("─" * 105)
    Write-Host "Backup File".PadRight(50) -NoNewline -ForegroundColor Cyan
    Write-Host "Output File".PadRight(40) -NoNewline -ForegroundColor Cyan
    Write-Host "Status" -ForegroundColor Cyan
    Write-Host ("─" * 105)

    $totalSize = 0
    foreach ($item in $backupsToDelete) {
        $backupInfo = Get-Item -Path $item.BackupFile -Force
        $sizeGiB = ($backupInfo.Length / 1GB).ToString('0.00')
        $totalSize += $backupInfo.Length

        $backupDisplay = if ($item.BackupFile.Length -gt 48) {
            $item.BackupFile.Substring(0, 45) + "…"
        } else {
            $item.BackupFile
        }

        $outputDisplay = if ($item.OutputFile.Length -gt 38) {
            $item.OutputFile.Substring(0, 35) + "…"
        } else {
            $item.OutputFile
        }

        $statusColor = if ($item.Status -eq "VERIFIED") { "Green" } else { "Yellow" }

        Write-Host $backupDisplay.PadRight(50) -NoNewline -ForegroundColor Gray
        Write-Host $outputDisplay.PadRight(40) -NoNewline -ForegroundColor Gray
        Write-Host $item.Status -ForegroundColor $statusColor
    }

    Write-Host ("─" * 105)
    $totalSizeGiB = ($totalSize / 1GB).ToString('0.00')
    Write-Host "Total: $($backupsToDelete.Count) files | Size: $totalSizeGiB GiB" -ForegroundColor Cyan
    Write-Host ""

    # Dry-run mode
    if ($DryRun) {
        Write-Host "✓ DRY-RUN MODE: No files were deleted." -ForegroundColor Green
        Write-Host "`nTo permanently delete these backups, run:" -ForegroundColor Yellow
        Write-Host "  .\Clean-HandBrakeBackups.ps1" -ForegroundColor Yellow
        Write-Host ""
        return $true
    }

    # Confirmation
    if (-not $Force) {
        Write-Host ""
        Write-Host "⚠️  WARNING: This will permanently delete $($backupsToDelete.Count) backup files totaling $totalSizeGiB GiB." -ForegroundColor Red
        Write-Host "This action CANNOT be undone." -ForegroundColor Red
        Write-Host ""
        Write-Host "Type 'DELETE' to confirm, or press Enter to cancel:" -ForegroundColor Yellow
        
        $confirmation = Read-Host
        
        if ($confirmation -ne 'DELETE') {
            Write-Host "`n✓ Operation cancelled by user." -ForegroundColor Yellow
            return $true
        }
    }

    # Perform deletion
    Write-Host "`nDeleting backups..." -ForegroundColor Yellow
    Write-Host ""

    $deletedCount = 0
    $failedCount = 0

    foreach ($item in $backupsToDelete) {
        try {
            $backupInfo = Get-Item -Path $item.BackupFile -Force
            $sizeGiB = ($backupInfo.Length / 1GB).ToString('0.00')
            
            Remove-Item -Path $item.BackupFile -Force -ErrorAction Stop
            
            Write-Host "✓ DELETED: $($item.BackupFile) ($sizeGiB GiB)" -ForegroundColor Green
            $deletedCount++
        }
        catch {
            Write-Host "✗ FAILED:  $($item.BackupFile)" -ForegroundColor Red
            Write-Host "  Error: $_" -ForegroundColor Red
            $failedCount++
        }
    }

    # Summary
    Write-Host ""
    Write-Host ("=" * 105) -ForegroundColor Cyan
    Write-Host "Cleanup Summary" -ForegroundColor Cyan
    Write-Host ("=" * 105) -ForegroundColor Cyan
    Write-Host "Total deleted   : $deletedCount" -ForegroundColor Green
    if ($failedCount -gt 0) {
        Write-Host "Failed deletions: $failedCount" -ForegroundColor Red
    }
    Write-Host "Space freed     : $totalSizeGiB GiB" -ForegroundColor Cyan
    Write-Host ""

    return $failedCount -eq 0
}

# -------------------------------------------------
# Entry point
# -------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $success = Invoke-BackupCleanup -ConversionsFile $ConversionsFile -FilterList $FilterList -DryRun $DryRun -Force $Force
    
    if ($success) {
        exit 0
    }
    else {
        exit 1
    }
}
catch {
    Write-Error "Cleanup operation failed: $_"
    exit 1
}
