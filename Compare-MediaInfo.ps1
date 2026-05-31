<#
.SYNOPSIS
    Compare MediaInfo properties of two files and perform QA evaluation for conversion.

.DESCRIPTION
    Executes MediaInfo CLI on two files, extracts key properties, and displays
    them in a side-by-side comparison with intelligent QA evaluation logic.
    Designed specifically for quality assurance verification after video conversion.

    Can be run in two modes:
    1. SINGLE PAIR: Compare two specific files with -File1 and -File2
    2. BATCH: Compare multiple conversions from a CSV file with -CsvPath

    EVALUATION LOGIC:
    • INFO (Expected): Different codecs, container formats, minor precision differences
    • WARN (Review): Duration differences 0.1-5%, stream size variance up to 15%, etc.
    • MISMATCH (Fail): Duration/size near 0, >70% delta, missing audio/subtitles, etc.

    Properties compared:
    - Container format and file extension
    - Video codec, resolution, duration, frame rate, stream size
    - Audio tracks (count, codec, language, stream size)
    - Subtitle tracks (count, language)
    - Detects empty/incomplete containers (Duration = 0)

.PARAMETER File1
    Path to the first file (typically the source/backup file). Use with File2.

.PARAMETER File2
    Path to the second file (typically the converted output file). Use with File1.

.PARAMETER CsvPath
    Path to CSV file with conversion pairs. Expected columns: BackupFile, OutputFile
    When specified, File1 and File2 are ignored and batch mode is used.

.PARAMETER MediaInfoExe
    Full path to MediaInfo.exe. If omitted the script tries to locate it
    in the typical install folder and the system PATH.

.PARAMETER IgnoreSize
    If $true, ignores file size differences in comparison (default: $false).
    Useful when comparing backups vs compressed output.

.EXIT CODES
    0 - Successful evaluation: All Pass or Pass with Warnings (no critical mismatches)
    1 - Failed evaluation: Any conversion has mismatches, manual intervention required

.EXAMPLE
    # Single pair comparison
    .\Compare-MediaInfo.ps1 -File1 'V:\Series\show_bak.avi' -File2 'V:\Series\show.mkv'

    # Batch comparison from CSV
    .\Compare-MediaInfo.ps1 -CsvPath 'V:\HandBrakeConversions.csv' `
        -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe'
#>
#Requires -Version 7.1

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$File1 = $null,

    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$File2 = $null,

    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath = $null,

    [Parameter(Mandatory=$false)]
    [string]$MediaInfoExe = $null,

    [Parameter(Mandatory=$false)]
    [bool]$IgnoreSize = $false
)

# -------------------------------------------------
# Helper: Locate MediaInfo
# -------------------------------------------------
function Get-MediaInfoPath {
    param([string]$Candidate)

    if ($Candidate -and (Test-Path $Candidate -PathType Leaf)) {
        return $Candidate
    }

    if ($env:MEDIAINFO_PATH -and (Test-Path $env:MEDIAINFO_PATH -PathType Leaf)) {
        return $env:MEDIAINFO_PATH
    }

    $onPath = Get-Command -Name 'MediaInfo' -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }

    throw "MediaInfo CLI not found. Pass -MediaInfoExe, set `$env:MEDIAINFO_PATH, or add MediaInfo to `$PATH."
}

# -------------------------------------------------
# Helper: Execute MediaInfo and parse JSON
# -------------------------------------------------
function Get-MediaProperties {
    param(
        [string]$FilePath,
        [string]$MediaInfoExe
    )

    $mediaInfoPath = Get-MediaInfoPath -Candidate $MediaInfoExe
    
    try {
        $rawOutput = (& $mediaInfoPath --Output=JSON $FilePath 2>&1) -join "`n"
        
        if ($LASTEXITCODE -ne 0) {
            throw "MediaInfo exited with code $LASTEXITCODE"
        }

        $parsed = $rawOutput | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
        
        if (-not $parsed.media -or -not $parsed.media.track) {
            throw "No media tracks found in output. File may be corrupted or unrecognized format."
        }
        
        return $parsed.media.track
    }
    catch {
        throw "Failed to parse MediaInfo for '$FilePath': $_"
    }
}

# -------------------------------------------------
# Helper: Extract key properties from tracks
# -------------------------------------------------

# Safe property accessor helper
function Get-SafeProperty {
    param([PSCustomObject]$Object, [string[]]$PropertyNames)
    if (-not $Object) { return $null }
    foreach ($prop in $PropertyNames) {
        try {
            $value = $Object.PSObject.Properties[$prop].Value
            if ($null -ne $value) { return $value }
        }
        catch { }
    }
    return $null
}

# Helper to format bytes to human-readable size
function Format-StreamSize {
    param([string]$Bytes)
    if (-not $Bytes) { return 'N/A' }
    try {
        $num = [int64]$Bytes
        if ($num -gt 1GB) { return ($num / 1GB).ToString('0.00') + ' GiB' }
        elseif ($num -gt 1MB) { return ($num / 1MB).ToString('0.00') + ' MiB' }
        elseif ($num -gt 1KB) { return ($num / 1KB).ToString('0.00') + ' KiB' }
        else { return $num.ToString() + ' B' }
    }
    catch { return 'N/A' }
}

function Get-ExtractedProperties {
    param(
        [PSCustomObject[]]$Tracks,
        [string]$FilePath
    )

    $general = $Tracks | Where-Object { $_.'@type' -eq 'General' } | Select-Object -First 1
    $video   = $Tracks | Where-Object { $_.'@type' -eq 'Video' }
    $audio   = $Tracks | Where-Object { $_.'@type' -eq 'Audio' }
    $text    = $Tracks | Where-Object { $_.'@type' -eq 'Text' }

    # Safe property access with defaults
    $fileSize = try { [int64]($general.FileSize ?? 0) } catch { 0 }
    $fileSizeGiB = if ($fileSize -gt 0) { ($fileSize / 1GB).ToString('0.00') } else { '0' }

    # Safe extraction of audio codecs
    $audioCodecs = @()
    try {
        $audioCodecs = @($audio | ForEach-Object { $_.Format } -ErrorAction SilentlyContinue | Where-Object { $_ })
    }
    catch { }

    # Safe extraction of audio languages
    $audioLanguages = @()
    try {
        $audioLanguages = @($audio | ForEach-Object { $_.Language } -ErrorAction SilentlyContinue | Where-Object { $_ })
    }
    catch { }

    # Safe extraction of audio stream sizes
    $audioStreamSizes = @()
    try {
        $audioStreamSizes = @($audio | ForEach-Object { Format-StreamSize $_.StreamSize } -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -ne 'N/A' })
    }
    catch { }

    # Safe extraction of audio stream sizes (raw)
    $audioStreamSizesRaw = @()
    try {
        $audioStreamSizesRaw = @($audio | ForEach-Object { $_.StreamSize } -ErrorAction SilentlyContinue | Where-Object { $_ })
    }
    catch { }

    # Safe extraction of text languages
    $textLanguages = @()
    try {
        $textLanguages = @($text | ForEach-Object { $_.Language } -ErrorAction SilentlyContinue | Where-Object { $_ })
    }
    catch { }

    # Safe video property extraction
    $videoFrameRate = $null
    $videoDuration = $null
    $videoStreamSize = $null
    $videoStreamSizeRaw = $null
    $videoWidth = $null
    $videoHeight = $null
    $videoDuration = $null

    if ($video.Count -gt 0) {
        try {
            $videoFrameRate = Get-SafeProperty $video[0] @('FrameRate_Original', 'FrameRate', 'Frame rate')
            $videoDuration = Get-SafeProperty $video[0] @('Duration')
            $videoStreamSize = Format-StreamSize (Get-SafeProperty $video[0] @('StreamSize', 'Stream size'))
            $videoStreamSizeRaw = Get-SafeProperty $video[0] @('StreamSize', 'Stream size')
            $videoWidth = try { [int](Get-SafeProperty $video[0] @('Width')) } catch { $null }
            $videoHeight = try { [int](Get-SafeProperty $video[0] @('Height')) } catch { $null }
        }
        catch { }
    }

    return @{
        FileName         = Split-Path -Leaf $FilePath
        Format           = $general.Format ?? 'Unknown'
        FileExtension    = $general.FileExtension ?? 'Unknown'
        FileSize         = $fileSize
        FileSizeDisplay  = "$fileSizeGiB GiB"
        Duration         = $general.Duration ?? 'N/A'
        
        VideoCount       = @($video).Count
        VideoCodec       = if ($video.Count -gt 0) { Get-SafeProperty $video[0] @('Format') } else { $null }
        VideoWidth       = $videoWidth
        VideoHeight      = $videoHeight
        VideoFrameRate   = $videoFrameRate
        VideoDuration    = $videoDuration
        VideoStreamSize  = $videoStreamSize
        VideoStreamSizeRaw = $videoStreamSizeRaw
        
        AudioCount       = @($audio).Count
        AudioCodecs      = $audioCodecs
        AudioLanguages   = $audioLanguages
        AudioStreamSizes = $audioStreamSizes
        AudioStreamSizesRaw = $audioStreamSizesRaw
        
        TextCount        = @($text).Count
        TextLanguages    = $textLanguages
    }
}

# -------------------------------------------------
# Helper: Format comparison row with highlighting
# -------------------------------------------------
function Format-ComparisonRow {
    param(
        [string]$Label,
        [string]$Value1,
        [string]$Value2,
        [bool]$Highlight = $false
    )

    # Convert null values to 'N/A'
    $Value1 = if ([string]::IsNullOrWhiteSpace($Value1) -or $Value1 -eq 'N/A') { 'N/A' } else { $Value1 }
    $Value2 = if ([string]::IsNullOrWhiteSpace($Value2) -or $Value2 -eq 'N/A') { 'N/A' } else { $Value2 }

    $labelWidth = 25
    $columnWidth = 40

    $label_display = $Label.PadRight($labelWidth)
    $value1_display = ($Value1 -replace '^(.{37})(.*)$', '$1…').PadRight($columnWidth)
    $value2_display = ($Value2 -replace '^(.{37})(.*)$', '$1…').PadRight($columnWidth)

    if ($Highlight -and $Value1 -ne $Value2) {
        Write-Host $label_display -NoNewline -ForegroundColor Cyan
        Write-Host $value1_display -NoNewline -ForegroundColor Red
        Write-Host $value2_display -ForegroundColor Green
    }
    else {
        Write-Host $label_display -NoNewline -ForegroundColor Cyan
        Write-Host $value1_display -NoNewline -ForegroundColor Gray
        Write-Host $value2_display -ForegroundColor Gray
    }
}

# -------------------------------------------------
# QA Evaluation: Parse duration and compare with tolerance
# -------------------------------------------------
function Compare-Duration {
    param(
        [string]$Duration1,
        [string]$Duration2
    )

    try {
        $d1 = [double]($Duration1 ?? 0)
        $d2 = [double]($Duration2 ?? 0)

        if ($d1 -eq 0 -or $d2 -eq 0) {
            return [PSCustomObject]@{
                Severity = "MISMATCH"
                Message  = "Duration is 0 or missing - file may be incomplete or corrupted"
                Value1   = $d1
                Value2   = $d2
            }
        }

        # Calculate percentage difference
        $delta = [Math]::Abs($d1 - $d2)
        $avgDuration = ($d1 + $d2) / 2
        $percentDiff = ($delta / $avgDuration) * 100

        if ($percentDiff -le 0.1) {
            # Likely just precision difference in decimal places
            return [PSCustomObject]@{
                Severity = "INFO"
                Message  = "Duration matches (precision difference in decimals)"
                Value1   = $d1
                Value2   = $d2
                PercentDiff = $percentDiff
            }
        }
        elseif ($percentDiff -le 5) {
            # Within acceptable margin (+/- 5%)
            return [PSCustomObject]@{
                Severity = "WARN"
                Message  = "Duration differs by $([Math]::Round($percentDiff, 2))% (within acceptable ±5% margin for codec frame selection)"
                Value1   = $d1
                Value2   = $d2
                PercentDiff = $percentDiff
            }
        }
        else {
            # Significant difference
            return [PSCustomObject]@{
                Severity = "MISMATCH"
                Message  = "Duration differs significantly by $([Math]::Round($percentDiff, 2))% (exceeds ±5% margin)"
                Value1   = $d1
                Value2   = $d2
                PercentDiff = $percentDiff
            }
        }
    }
    catch {
        return [PSCustomObject]@{
            Severity = "MISMATCH"
            Message  = "Failed to parse duration values: $_"
        }
    }
}

# -------------------------------------------------
# QA Evaluation: Parse stream size and compare
# -------------------------------------------------
function Compare-StreamSize {
    param(
        [string]$Size1Raw,
        [string]$Size2Raw,
        [string]$Label = "Stream"
    )

    try {
        $s1 = [int64]($Size1Raw ?? 0)
        $s2 = [int64]($Size2Raw ?? 0)

        if ($s1 -lt 1MB -or $s2 -lt 1MB) {
            return [PSCustomObject]@{
                Severity = "MISMATCH"
                Message  = "$Label size critically low - file may be incomplete or corrupted"
                Value1   = $s1
                Value2   = $s2
            }
        }

        $delta = [Math]::Abs($s1 - $s2)
        $avgSize = ($s1 + $s2) / 2
        $percentDiff = ($delta / $avgSize) * 100

        if ($percentDiff -le 5) {
            return [PSCustomObject]@{
                Severity = "INFO"
                Message  = "$Label size differs by $([Math]::Round($percentDiff, 2))% (expected due to codec efficiency)"
                Value1   = $s1
                Value2   = $s2
                PercentDiff = $percentDiff
            }
        }
        elseif ($percentDiff -le 15) {
            return [PSCustomObject]@{
                Severity = "INFO"
                Message  = "$Label size differs by $([Math]::Round($percentDiff, 2))% (expected codec optimization)"
                Value1   = $s1
                Value2   = $s2
                PercentDiff = $percentDiff
            }
        }
        elseif ($percentDiff -lt 70) {
            return [PSCustomObject]@{
                Severity = "WARN"
                Message  = "$Label size differs by $([Math]::Round($percentDiff, 2))% - review encoding quality settings"
                Value1   = $s1
                Value2   = $s2
                PercentDiff = $percentDiff
            }
        }
        else {
            return [PSCustomObject]@{
                Severity = "MISMATCH"
                Message  = "$Label size differs by $([Math]::Round($percentDiff, 2))% - significant quality degradation or encoding error"
                Value1   = $s1
                Value2   = $s2
                PercentDiff = $percentDiff
            }
        }
    }
    catch {
        return [PSCustomObject]@{
            Severity = "WARN"
            Message  = "Failed to parse $Label size: $_"
        }
    }
}

# -------------------------------------------------
# QA Evaluation: Core track comparison logic
# -------------------------------------------------
function Invoke-QAComparison {
    param(
        [PSCustomObject]$Props1,
        [PSCustomObject]$Props2
    )

    $findings = @()

    # ===== VIDEO EVALUATION =====
    
    # Video codec - different codec is EXPECTED for conversion
    if ([string]$Props1.VideoCodec -ne [string]$Props2.VideoCodec) {
        $findings += [PSCustomObject]@{
            Category = "VIDEO"
            Severity = "INFO"
            Message = "Video codec changed: $($Props1.VideoCodec) → $($Props2.VideoCodec) (expected for conversion)"
        }
    }

    # Video resolution - should match
    if ($Props1.VideoWidth -and $Props2.VideoWidth -and $Props1.VideoHeight -and $Props2.VideoHeight) {
        if ($Props1.VideoWidth -ne $Props2.VideoWidth -or $Props1.VideoHeight -ne $Props2.VideoHeight) {
            $findings += [PSCustomObject]@{
                Category = "VIDEO"
                Severity = "MISMATCH"
                Message = "Video resolution mismatch: $($Props1.VideoWidth)×$($Props1.VideoHeight) → $($Props2.VideoWidth)×$($Props2.VideoHeight)"
            }
        }
    }

    # Video duration
    if ($Props1.VideoDuration -and $Props2.VideoDuration) {
        $durationComp = Compare-Duration $Props1.VideoDuration $Props2.VideoDuration
        $findings += [PSCustomObject]@{
            Category = "VIDEO"
            Severity = $durationComp.Severity
            Message = $durationComp.Message
        }
    }

    # Video stream size
    if ($Props1.VideoStreamSizeRaw -and $Props2.VideoStreamSizeRaw) {
        $sizeComp = Compare-StreamSize $Props1.VideoStreamSizeRaw $Props2.VideoStreamSizeRaw "Video"
        $findings += [PSCustomObject]@{
            Category = "VIDEO"
            Severity = $sizeComp.Severity
            Message = $sizeComp.Message
        }
    }

    # ===== AUDIO EVALUATION =====

    # Audio track count - should match
    if ($Props1.AudioCount -ne $Props2.AudioCount) {
        $findings += [PSCustomObject]@{
            Category = "AUDIO"
            Severity = "MISMATCH"
            Message = "Audio track count mismatch: $($Props1.AudioCount) → $($Props2.AudioCount)"
        }
    }

    # Audio stream sizes
    if ($Props1.AudioStreamSizesRaw.Count -gt 0 -and $Props2.AudioStreamSizesRaw.Count -gt 0) {
        for ($i = 0; $i -lt [Math]::Min($Props1.AudioStreamSizesRaw.Count, $Props2.AudioStreamSizesRaw.Count); $i++) {
            $sizeComp = Compare-StreamSize $Props1.AudioStreamSizesRaw[$i] $Props2.AudioStreamSizesRaw[$i] "Audio Track $($i+1)"
            $findings += [PSCustomObject]@{
                Category = "AUDIO"
                Severity = $sizeComp.Severity
                Message = $sizeComp.Message
            }
        }
    }

    # ===== SUBTITLE EVALUATION =====

    # Subtitle track count - should match (if present)
    if ($Props1.TextCount -ne $Props2.TextCount) {
        if ($Props2.TextCount -eq 0 -and $Props1.TextCount -gt 0) {
            $findings += [PSCustomObject]@{
                Category = "SUBTITLE"
                Severity = "MISMATCH"
                Message = "Subtitle tracks lost during conversion: $($Props1.TextCount) → 0"
            }
        }
        else {
            $findings += [PSCustomObject]@{
                Category = "SUBTITLE"
                Severity = "WARN"
                Message = "Subtitle track count changed: $($Props1.TextCount) → $($Props2.TextCount)"
            }
        }
    }

    # ===== FILE CONTAINER EVALUATION =====

    # Container format changes are expected
    if ([string]$Props1.Format -ne [string]$Props2.Format) {
        $findings += [PSCustomObject]@{
            Category = "CONTAINER"
            Severity = "INFO"
            Message = "Container format changed: $($Props1.Format) → $($Props2.Format) (expected for conversion)"
        }
    }

    return $findings
}

# -------------------------------------------------
# Helper: Build comparison items array from parameters or CSV
# -------------------------------------------------
function Get-ComparisonItems {
    param(
        [string]$File1,
        [string]$File2,
        [string]$CsvPath
    )

    $items = @()

    if ($CsvPath) {
        # Read CSV and build items from BackupFile and OutputFile columns
        try {
            $csv = Import-Csv -Path $CsvPath -ErrorAction Stop
            foreach ($row in $csv) {
                $backupFile = $row.BackupFile
                $outputFile = $row.OutputFile

                if (-not (Test-Path $backupFile -PathType Leaf)) {
                    Write-Warning "Skipping: Backup file not found: $backupFile"
                    continue
                }
                if (-not (Test-Path $outputFile -PathType Leaf)) {
                    Write-Warning "Skipping: Output file not found: $outputFile"
                    continue
                }

                $items += [PSCustomObject]@{
                    File1 = $backupFile
                    File2 = $outputFile
                }
            }
        }
        catch {
            Write-Error "Failed to read CSV file '$CsvPath': $_"
            exit 1
        }
    }
    else {
        # Single pair mode
        if ($File1 -and $File2) {
            $items += [PSCustomObject]@{
                File1 = $File1
                File2 = $File2
            }
        }
        else {
            Write-Error "Please specify either (-File1 and -File2) or (-CsvPath)"
            exit 1
        }
    }

    if ($items.Count -eq 0) {
        Write-Error "No valid file pairs to compare"
        exit 1
    }

    return $items
}

# -------------------------------------------------
# Main: Compare files
# -------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Build comparison items array
$comparisonItems = Get-ComparisonItems -File1 $File1 -File2 $File2 -CsvPath $CsvPath
$summaryResults = @()
$hasAnyMismatch = $false

try {
    # Determine if batch mode (multiple items)
    $isBatchMode = $comparisonItems.Count -gt 1
    
    if ($isBatchMode) {
        Write-Host "`n" -NoNewline
        Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host "  BATCH QA EVALUATION - Processing $($comparisonItems.Count) conversions" -ForegroundColor Yellow
        Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host ""
    }

    # Process each comparison item
    foreach ($item in $comparisonItems) {
        $comparisonFile1 = $item.File1
        $comparisonFile2 = $item.File2

        if (-not $isBatchMode) {
            Write-Host "`n" -NoNewline
            Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
            Write-Host "  MediaInfo Comparison: Side-by-Side Diff View" -ForegroundColor Yellow
            Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
            Write-Host ""
        }

        # Extract properties from both files
        if ($isBatchMode) {
            Write-Host "Processing: $(Split-Path -Leaf $comparisonFile1) → $(Split-Path -Leaf $comparisonFile2)" -ForegroundColor Yellow
        }
        else {
            Write-Host "[1/3] Extracting properties from File 1..." -ForegroundColor Cyan
        }

        try {
            $tracks1 = Get-MediaProperties -FilePath $comparisonFile1 -MediaInfoExe $MediaInfoExe
            $props1 = Get-ExtractedProperties -Tracks $tracks1 -FilePath $comparisonFile1
        }
        catch {
            Write-Error "Failed to extract properties from File 1: $_"
            exit 1
        }

        if (-not $isBatchMode) {
            Write-Host "[2/3] Extracting properties from File 2..." -ForegroundColor Cyan
        }

        try {
            $tracks2 = Get-MediaProperties -FilePath $comparisonFile2 -MediaInfoExe $MediaInfoExe
            $props2 = Get-ExtractedProperties -Tracks $tracks2 -FilePath $comparisonFile2
        }
        catch {
            Write-Error "Failed to extract properties from File 2: $_"
            exit 1
        }

        if (-not $isBatchMode) {
            Write-Host "[3/3] Preparing comparison..." -ForegroundColor Cyan
        }

        Write-Host ""

        # Header
        Write-Host "Property".PadRight(25) -NoNewline -ForegroundColor Cyan
        Write-Host "File 1 (Source/Backup)".PadRight(40) -NoNewline -ForegroundColor Yellow
        Write-Host "File 2 (Output)" -ForegroundColor Yellow
        Write-Host "".PadRight(25) -NoNewline
        Write-Host $props1.FileName.PadRight(40) -NoNewline -ForegroundColor DarkGray
        Write-Host $props2.FileName -ForegroundColor DarkGray
        Write-Host ("─" * 105)

        # Container & Format
        Format-ComparisonRow "Format:" ([string]($props1.Format ?? 'N/A')) ([string]($props2.Format ?? 'N/A')) $true
        Format-ComparisonRow "Extension:" ([string]($props1.FileExtension ?? 'N/A')) ([string]($props2.FileExtension ?? 'N/A')) $true
        
        if (-not $IgnoreSize) {
            Format-ComparisonRow "File Size:" ([string]$props1.FileSizeDisplay) ([string]$props2.FileSizeDisplay) $true
        }

        Format-ComparisonRow "Duration:" ([string]($props1.Duration ?? 'N/A')) ([string]($props2.Duration ?? 'N/A')) $true
        Write-Host ("─" * 105)

        # Video
        Write-Host "VIDEO TRACKS".PadRight(25) -ForegroundColor Magenta
        Format-ComparisonRow "Count:" ([string]$props1.VideoCount) ([string]$props2.VideoCount) $true
        Format-ComparisonRow "Codec:" ([string]($props1.VideoCodec ?? "None")) ([string]($props2.VideoCodec ?? "None")) $true
        Format-ComparisonRow "Resolution:" "$(if ($props1.VideoWidth) { "$($props1.VideoWidth)×$($props1.VideoHeight)" } else { "N/A" })" "$(if ($props2.VideoWidth) { "$($props2.VideoWidth)×$($props2.VideoHeight)" } else { "N/A" })" $true
        Format-ComparisonRow "Frame Rate:" ([string]($props1.VideoFrameRate ?? "N/A")) ([string]($props2.VideoFrameRate ?? "N/A")) $true
        Format-ComparisonRow "Duration:" ([string]($props1.VideoDuration ?? "N/A")) ([string]($props2.VideoDuration ?? "N/A")) $true
        Format-ComparisonRow "Stream Size:" ([string]($props1.VideoStreamSize ?? "N/A")) ([string]($props2.VideoStreamSize ?? "N/A")) $true
        Write-Host ("─" * 105)

        # Audio
        Write-Host "AUDIO TRACKS".PadRight(25) -ForegroundColor Magenta
        Format-ComparisonRow "Count:" ([string]$props1.AudioCount) ([string]$props2.AudioCount) $true
        Format-ComparisonRow "Codecs:" $(if ($props1.AudioCodecs -and $props1.AudioCodecs.Count -gt 0) { $props1.AudioCodecs -join ", " } else { "None" }) $(if ($props2.AudioCodecs -and $props2.AudioCodecs.Count -gt 0) { $props2.AudioCodecs -join ", " } else { "None" }) $true
        Format-ComparisonRow "Languages:" $(if ($props1.AudioLanguages -and $props1.AudioLanguages.Count -gt 0) { $props1.AudioLanguages -join ", " } else { "Not set" }) $(if ($props2.AudioLanguages -and $props2.AudioLanguages.Count -gt 0) { $props2.AudioLanguages -join ", " } else { "Not set" }) $true
        Format-ComparisonRow "Stream Sizes:" $(if ($props1.AudioStreamSizes -and $props1.AudioStreamSizes.Count -gt 0) { $props1.AudioStreamSizes -join ", " } else { "None" }) $(if ($props2.AudioStreamSizes -and $props2.AudioStreamSizes.Count -gt 0) { $props2.AudioStreamSizes -join ", " } else { "None" }) $true
        Write-Host ("─" * 105)

        # Subtitles
        Write-Host "SUBTITLE TRACKS".PadRight(25) -ForegroundColor Magenta
        Format-ComparisonRow "Count:" ([string]$props1.TextCount) ([string]$props2.TextCount) $true
        Format-ComparisonRow "Languages:" $(if ($props1.TextLanguages -and $props1.TextLanguages.Count -gt 0) { $props1.TextLanguages -join ", " } else { "None" }) $(if ($props2.TextLanguages -and $props2.TextLanguages.Count -gt 0) { $props2.TextLanguages -join ", " } else { "None" }) $true
        Write-Host ("─" * 105)

        # QA Evaluation Summary
        Write-Host ""

        $findings = Invoke-QAComparison -Props1 $props1 -Props2 $props2

        # Categorize findings by severity
        $infoFindings = @($findings | Where-Object { $_.Severity -eq 'INFO' })
        $warnFindings = @($findings | Where-Object { $_.Severity -eq 'WARN' })
        $mismatchFindings = @($findings | Where-Object { $_.Severity -eq 'MISMATCH' })

        if (-not $isBatchMode) {
            Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║                    QA EVALUATION RESULTS                       ║" -ForegroundColor Cyan
            Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host ""

            # INFO findings
            if ($infoFindings.Count -gt 0) {
                Write-Host "ℹ️  INFORMATIONAL ($($infoFindings.Count) items):" -ForegroundColor Cyan
                foreach ($finding in $infoFindings) {
                    Write-Host "   ✓ [$($finding.Category)] $($finding.Message)" -ForegroundColor Green
                }
                Write-Host ""
            }

            # WARNING findings
            if ($warnFindings.Count -gt 0) {
                Write-Host "⚠️  WARNINGS ($($warnFindings.Count) items) - Review recommended:" -ForegroundColor Yellow
                foreach ($finding in $warnFindings) {
                    Write-Host "   ⚠ [$($finding.Category)] $($finding.Message)" -ForegroundColor Yellow
                }
                Write-Host ""
            }

            # MISMATCH findings
            if ($mismatchFindings.Count -gt 0) {
                Write-Host "❌ MISMATCHES ($($mismatchFindings.Count) items) - Manual intervention required:" -ForegroundColor Red
                foreach ($finding in $mismatchFindings) {
                    Write-Host "   ✗ [$($finding.Category)] $($finding.Message)" -ForegroundColor Red
                }
                Write-Host ""
            }
        }
        # Determine verdict and collect for summary
        if ($mismatchFindings.Count -eq 0) {
            if ($warnFindings.Count -eq 0) {
                $verdict = "✅ PASS"
                $verdictColor = "Green"
            }
            else {
                $verdict = "⚠️  PASS (WARNINGS)"
                $verdictColor = "Yellow"
            }
        }
        else {
            $verdict = "❌ FAIL"
            $verdictColor = "Red"
            $hasAnyMismatch = $true
        }
        # Display verdict only if single mode
        if (-not $isBatchMode) {
            Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "║  $verdict - Conversion complete                                 ║" -ForegroundColor $verdictColor
            Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host ""
        }

        # Collect summary result
        $summaryResults += [PSCustomObject]@{
            File1 = (Split-Path -Leaf $comparisonFile1)
            File2 = (Split-Path -Leaf $comparisonFile2)
            Verdict = $verdict
            VerdictColor = $verdictColor
            MismatchCount = $mismatchFindings.Count
            WarningCount = $warnFindings.Count
            InfoCount = $infoFindings.Count
        }
    }  # End foreach loop

    # Display summary table for batch or multi-file comparisons
    if ($isBatchMode -or $summaryResults.Count -gt 1) {
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║                                    QA EVALUATION SUMMARY TABLE                                                 ║" -ForegroundColor Cyan
        Write-Host "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "║ File 1                                   | File 2                                   | Verdict                  ║" -ForegroundColor Cyan
        Write-Host "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        
        foreach ($result in $summaryResults) {
            $file1Display = if ($result.File1.Length -gt 38) { $result.File1.Substring(0, 35) + "…" } else { $result.File1 }
            $file2Display = if ($result.File2.Length -gt 38) { $result.File2.Substring(0, 35) + "…" } else { $result.File2 }
            $file1Padded = $file1Display.PadRight(40)
            $file2Padded = $file2Display.PadRight(40)
            $verdictPadded = switch ($result.VerdictColor) {
                "Green" { $result.Verdict.PadRight(24) }
                "Yellow" { $result.Verdict.PadRight(26) }
                "Red" { $result.Verdict.PadRight(24) }
                default { $result.Verdict.PadRight(24) }
            }

            Write-Host "║ $file1Padded | $file2Padded | " -NoNewline -ForegroundColor Cyan
            Write-Host "$verdictPadded" -ForegroundColor $result.VerdictColor -NoNewline
            Write-Host "║" -ForegroundColor Cyan
        }

        Write-Host "╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        
        # Display overall summary
        $passCount = ($summaryResults | Where-Object { $_.MismatchCount -eq 0 })?.Count ?? 0
        $failCount = ($summaryResults | Where-Object { $_.MismatchCount -gt 0 })?.Count ?? 0
        Write-Host "Overall Results: $($summaryResults.Count) files processed | " -NoNewline -ForegroundColor Cyan
        Write-Host "$passCount passed" -ForegroundColor Green -NoNewline
        Write-Host " | " -ForegroundColor Cyan -NoNewline
        Write-Host "$failCount failed" -ForegroundColor Red
        Write-Host ""
    }

    # Set final exit code
    if ($hasAnyMismatch) {
        exit 1  # Failure - at least one conversion has mismatches
    }
    else {
        exit 0  # Success - all conversions passed or passed with warnings
    }
}
catch {
    Write-Error "Error during QA evaluation: $_"
    exit 1
}
