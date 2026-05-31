<#
.SYNOPSIS
    Recursively scans a folder tree, extracts MediaInfo data, and produces JSON + CSV
    outputs.  Adds a persistent status file so the run can be safely resumed.

.DESCRIPTION
    • Walks every file under the supplied root path.
    • Calls MediaInfo‑CLI to obtain container format and video codec.
    • Builds a hierarchical object that mirrors the directory structure.
    • Writes the hierarchy to MediaInfoTree.json.
    • Emits HandBrakeQueue.csv for files that need re‑encoding.
    • Persists a JSON status file (ScanMediaInfoStatus.json) that records
      which directories have already been scanned.  On restart the script
      reads that file and continues where it left off.

.PARAMETER RootPath
    The folder to start scanning (e.g. V:\Series\).

.PARAMETER MediaInfoExe
    Full path to MediaInfo.exe.  If omitted the script searches the default
    install location and the system PATH.

.EXAMPLE

    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted
    .\Scan-MediaInfo.ps1 -RootPath 'V:\Series\'
    .\Scan-MediaInfo.ps1 -RootPath 'V:\Series\' -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe'
	pwsh -NoProfile -ExecutionPolicy Bypass -File .\Scan-MediaInfo.ps1 -RootPath 'V:\Series_M\One Pizza (1999) {tmdb-37854}\Season 00\' -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe'
#>
#Requires -Version 7.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $RootPath,

    [string] $MediaInfoExe = $null,
    [int]    $MaxDepth     = 0,
    [string] $StatusFile   = (Join-Path $PWD.Path  'ScanMediaInfoStatus.json'),
    [string] $JsonOut      = (Join-Path $PWD.Path  'MediaInfoTree.json'),
    [string] $CsvOut       = (Join-Path $PWD.Path  'HandBrakeQueue.csv')
)



function Write-DebugInfo { param([string] $Message) if ($PSBoundParameters.ContainsKey('Verbose') -or $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Verbose')) { Write-Verbose $Message } }

function Get-MediaInfoPath {
    [OutputType([string])]
    param(
        [string]$MediaInfoExe
    )

    # 1. Explicit path passed via -MediaInfoExe parameter
    if ($MediaInfoExe -and (Test-Path $MediaInfoExe -PathType Leaf)) {
        return $MediaInfoExe
    }

    # 2. Honour an env override (e.g. $env:MEDIAINFO_PATH = 'D:\tools\MediaInfo.exe')
    if ($env:MEDIAINFO_PATH -and (Test-Path $env:MEDIAINFO_PATH -PathType Leaf)) {
        return $env:MEDIAINFO_PATH
    }

    # 3. Fall back to whatever is on $PATH
    $onPath = Get-Command -Name 'MediaInfo' -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }

    throw "MediaInfo CLI not found. Pass -MediaInfoExe, set `$env:MEDIAINFO_PATH, or add MediaInfo to `$PATH."
}

function Save-Status { $payload = [pscustomobject]@{ ProcessedFolders = $ProcessedFolders }; $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $StatusFile -Encoding UTF8 }

# -----------------------------------------------------------------------------
# Call MediaInfo CLI and parse the XML output into an XmlDocument.
# -----------------------------------------------------------------------------
function Invoke-MediaInfoXml {
    [CmdletBinding()]
    [OutputType([xml])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    $mediaInfoExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
    $rawOutput    = (& $mediaInfoExe --Output=XML $FilePath 2>&1) -join "`n"  # fix: join Object[] to single string

    if ($LASTEXITCODE -ne 0) {
        throw "MediaInfo exited with code $LASTEXITCODE for file: $FilePath"
    }

    try {
        $doc = [xml]$rawOutput
        return , $doc             # fix: unary comma prevents PowerShell enumerating XmlDocument child nodes
    }
    catch {
        throw "Failed to parse MediaInfo XML output: $_"
    }
}

# -----------------------------------------------------------------------------
# Call MediaInfo CLI and parse the JSON output into a PSCustomObject.
# -----------------------------------------------------------------------------
function Invoke-MediaInfoJson {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    $mediaInfoExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
    $rawOutput    = (& $mediaInfoExe --Output=JSON $FilePath 2>&1) -join "`n"  # fix: join Object[] to single string

    if ($LASTEXITCODE -ne 0) {
        throw "MediaInfo exited with code $LASTEXITCODE for file: $FilePath"
    }

    try {
        $rawOutput | ConvertFrom-Json -NoEnumerate
    }
    catch {
        throw "Failed to parse MediaInfo JSON output: $_"
    }
}

# -----------------------------------------------------------------------------
# Extract the desired output fields from MediaInfo XML results.
#
# Note: this function currently reads a minimal set of fields. If you need
# additional MediaInfo metadata, extend this function and the returned object
# shape accordingly.
# -----------------------------------------------------------------------------
function Get-MediaInfoPropertiesFromXml {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    $xml = Invoke-MediaInfoXml -FilePath $FilePath -MediaInfoExe $MediaInfoExe

    $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('mi', 'https://mediaarea.net/mediainfo')

    $generalTrack = $xml.SelectSingleNode('//mi:track[@type="General"]', $ns)
    $videoTrack   = $xml.SelectSingleNode('//mi:track[@type="Video"]',   $ns)

    $fileExtensionNode = if ($generalTrack) { $generalTrack.SelectSingleNode('mi:FileExtension', $ns) } else { $null }
    $videoCountNode    = if ($generalTrack) { $generalTrack.SelectSingleNode('mi:VideoCount',    $ns) } else { $null }
    $videoCodecNode    = if ($videoTrack)   { $videoTrack.SelectSingleNode('mi:Format',         $ns) } else { $null }

    $fileExtension = if ($fileExtensionNode) { $fileExtensionNode.InnerText } else { $null }
    $videoCount    = if ($videoCountNode) { [int]$videoCountNode.InnerText } else { 0 }
    $hasVideo      = $videoCount -gt 0
    $videoCodec    = if ($videoCodecNode) { $videoCodecNode.InnerText } else { $null }

    [PSCustomObject]@{
        Source        = 'XML'
        FileExtension = $fileExtension
        HasVideo      = $hasVideo
        VideoCodec    = if ($hasVideo) { $videoCodec } else { $null }
    }
}

# -----------------------------------------------------------------------------
# Extract the desired output fields from MediaInfo JSON results.
#
# Note: the JSON parser currently returns a minimal set of fields that mirrors
# the XML parser output shape. It does not propagate the full MediaInfo record.
# -----------------------------------------------------------------------------
function Get-MediaInfoPropertiesFromJson {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    $parsed = Invoke-MediaInfoJson -FilePath $FilePath -MediaInfoExe $MediaInfoExe
    $tracks = $parsed.media.track

    $generalTrack = $tracks | Where-Object { $_.'@type' -eq 'General' } | Select-Object -First 1
    $videoTrack   = $tracks | Where-Object { $_.'@type' -eq 'Video'   } | Select-Object -First 1

    $fileExtension = if ($generalTrack) { $generalTrack.FileExtension } else { $null }
    $videoCount    = if ($generalTrack) { [int]$generalTrack.VideoCount } else { 0 }
    $hasVideo      = $videoCount -gt 0
    $videoCodec    = if ($videoTrack) { $videoTrack.Format } else { $null }

    [PSCustomObject]@{
        Source        = 'JSON'
        FileExtension = $fileExtension
        HasVideo      = $hasVideo
        VideoCodec    = if ($hasVideo) { $videoCodec } else { $null }
    }
}


function Get-MediaInfoData {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [ValidateSet('XML','JSON')]
        [string]$Parser = 'XML',

        [string]$MediaInfoExe = $script:MediaInfoExe
    )

    <#
        Retrieves MediaInfo metadata for a single file and returns a consistent
        object shape for the caller.

        The function supports both XML and JSON parsing backends, with XML as
        the default. If MediaInfo fails for any reason, it returns a stub object
        instead of throwing, so the scan can continue.

        Current returned object shape:
          Source     - XML or JSON parser used
          Container  - general file extension / container indication
          HasVideo   - whether any video stream was detected
          VideoCodec - detected video codec from the first video track
          Parser     - parser backend used

        Missing MediaInfo fields that are not currently propagated include:
          - General.Format / container format name
          - General.Format_Version
          - General.FileSize, Duration, OverallBitRate
          - General.Title / Movie / Encoded_Date
          - General.AudioCount / MenuCount / subtitle information
          - Video track width/height/frame rate/bit depth/codec profile
          - Audio codec and language data
    #>

    try {
        switch ($Parser.ToUpperInvariant()) {
            'JSON' {
                $info = Get-MediaInfoPropertiesFromJson -FilePath $FilePath -MediaInfoExe $MediaInfoExe
            }
            default {
                $info = Get-MediaInfoPropertiesFromXml  -FilePath $FilePath -MediaInfoExe $MediaInfoExe
            }
        }

        return [pscustomobject]@{
            Source      = $info.Source
            Container   = $info.FileExtension
            HasVideo    = $info.HasVideo
            VideoCodec  = $info.VideoCodec
            Parser      = $Parser
        }
    }
    catch {
        Write-Warning "MediaInfo failed for '$FilePath' with parser '$Parser': $_"
        return [pscustomobject]@{
            Source      = $Parser
            Container   = $null
            HasVideo    = $false
            VideoCodec  = $null
            Error       = $_.Exception.Message
        }
    }
}


# -----------------------------------------------------------------------------
# Walk the target directory tree and collect media metadata for every file.
# The tree structure is preserved so the output JSON mirrors the original layout.
# -----------------------------------------------------------------------------
function Build-Tree {
    param([string] $Root, [int] $MaxDepth = 0)

    $rootNode = [pscustomobject]@{ Name = Split-Path $Root -Leaf; FullPath = $Root; Files = @(); Subfolders = @() }
    $stack = New-Object System.Collections.Stack
    $stack.Push([pscustomobject]@{ Node = $rootNode; Path = $Root; Depth = 1 })

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop(); $node = $frame.Node; $path = $frame.Path; $depth = $frame.Depth

        if ($ProcessedFolders -contains $path) { Write-Host "⏭️  SKIPPED (processed): $path" -ForegroundColor DarkGray; continue }

        Write-Host "`nScanning: $path" -ForegroundColor Yellow

        try { $files = Get-ChildItem -Path $path -File -Force -ErrorAction Stop } catch { Write-Warning "Failed to list files in $path : ${_}"; $files = @() }

        foreach ($f in $files) {
            $info = Get-MediaInfoData -FilePath $f.FullName -MediaInfoExe $MediaInfoExe
            $node.Files += [pscustomobject]@{
                FileName   = $f.Name
                FullPath   = $f.FullName
                Extension  = $f.Extension.TrimStart('.')
                Container  = $info.Container
                HasVideo   = $info.HasVideo
                VideoCodec = $info.VideoCodec
            }
        }

        if ($MaxDepth -le 0 -or $depth -lt $MaxDepth) {
            try { $subs = Get-ChildItem -Path $path -Directory -Force -ErrorAction Stop } catch { Write-Warning "Failed to list subfolders in $path : ${_}"; $subs = @() }
            foreach ($s in $subs) {
                $childNode = [pscustomobject]@{ Name = $s.Name; FullPath = $s.FullName; Files = @(); Subfolders = @() }
                $node.Subfolders += $childNode
                $stack.Push([pscustomobject]@{ Node = $childNode; Path = $s.FullName; Depth = $depth + 1 })
            }
        }

        $ProcessedFolders += $path
        Save-Status
    }

    return $rootNode
}


# -----------------------------------------------------------------------------
# Build the HandBrake re-encode queue from the scanned tree.
# Only files with a detected video stream are considered; H.265/AV1 are skipped.
# -----------------------------------------------------------------------------
function Group-FileQueue {
    param([pscustomobject] $Node)
    foreach ($file in $Node.Files) {
        $displayCodec = if ($file.VideoCodec) { $file.VideoCodec } else { '<no codec>' }
        Write-Host "Processing: $($file.FullPath) | HasVideo: $($file.HasVideo) | Codec: $displayCodec"

        if (-not $file.HasVideo) { continue }

        $codecNormalized = ''
        if ($file.VideoCodec) { $codecNormalized = $file.VideoCodec.ToString().ToUpperInvariant() }

        $isH265 = $codecNormalized -match 'HEVC|H\.265|X265|V_MPEGH/ISO/HEVC'
        $isAV1  = $codecNormalized -match 'AV1'

        if (-not ($isH265 -or $isAV1)) {
            $target = [IO.Path]::ChangeExtension($file.FullPath, '.mkv')
            $row = [pscustomobject]@{ SourceFile = $file.FullPath; TargetFile = $target; DetectedCodec = $file.VideoCodec; DesiredCodec = 'H.265' }
            $null = $csvRows.Add($row)
        }
    }
    foreach ($sub in $Node.Subfolders) { Group-FileQueue -Node $sub }
}

# -----------------------------------------------------------------------------
# Recursive file counter for the tree structure.
# This avoids unreliable aggregation from Measure-Object across nested collections.
# -----------------------------------------------------------------------------
function Measure-TreeFilesCount {
    param([pscustomobject] $Node)
    $count = 0
    if ($Node.Files) { $count += ($Node.Files).Count }
    if ($Node.Subfolders) {
        foreach ($s in $Node.Subfolders) { $count += Measure-TreeFilesCount -Node $s }
    }
    return $count
}

# -----------------------------------------------------------------------------
# Recursive counter for detected video files in the scan tree.
# -----------------------------------------------------------------------------
function Get-VideoFileCount {
    param([pscustomobject] $Node)
    $count = 0
    if ($Node.Files) { $count += ($Node.Files | Where-Object { $_.HasVideo }).Count }
    if ($Node.Subfolders) {
        foreach ($s in $Node.Subfolders) { $count += Get-VideoFileCount -Node $s }
    }
    return $count
}

Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------
# Persist scan progress so the run can resume cleanly on the next invocation.
# The status file stores processed folders and is read at startup.
# -----------------------------------------------------------------------------
# Status persistence
$ProcessedFolders = @()
if (Test-Path $StatusFile) {
    try { $status = Get-Content -Raw -Path $StatusFile | ConvertFrom-Json -ErrorAction Stop; if ($status.ProcessedFolders) { $ProcessedFolders = [System.Collections.ArrayList]@($status.ProcessedFolders) } }
    catch { Write-Warning "Failed to read status file '${StatusFile}': ${_}. Starting fresh."; $ProcessedFolders = @() }
} else { $ProcessedFolders = @() }

$csvRows = New-Object System.Collections.ArrayList

$MediaInfoExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
Write-Host "Using MediaInfo: $MediaInfoExe" -ForegroundColor Cyan

Write-Host "`n=== Starting scan ===`n" -ForegroundColor Cyan
$rootResolved = (Resolve-Path $RootPath).Path
$tree = Build-Tree -Root $rootResolved -MaxDepth $MaxDepth

try { $tree | ConvertTo-Json -Depth 99 | Set-Content -Path $JsonOut -Encoding UTF8; Write-Host "`n✅ JSON written to $JsonOut" -ForegroundColor Green } catch { Write-Warning "Failed to write JSON: ${_}" }

Group-FileQueue -Node $tree
try { $csvRows | Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8; Write-Host "`n✅ CSV written to $CsvOut ($($csvRows.Count) rows)" -ForegroundColor Green } catch { Write-Warning "Failed to write CSV: ${_}" }

$folderCount = ($ProcessedFolders | Measure-Object).Count
$fileCount = Measure-TreeFilesCount -Node $tree
$videoCount = Get-VideoFileCount -Node $tree

Write-Host "`n=== Scan completed ===" -ForegroundColor Cyan
Write-Host "Folders processed       : $folderCount"
Write-Host "Total files examined    : $fileCount"
Write-Host "Total video files found : $videoCount"
Write-Host "Re-encode queue entries : $($csvRows.Count)"
Write-Host "`nYou may re-run this script; it will resume from last saved folder." -ForegroundColor Yellow
