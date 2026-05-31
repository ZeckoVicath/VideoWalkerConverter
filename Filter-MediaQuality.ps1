<#
.SYNOPSIS
    Scans a folder tree and filters video files based on quality criteria.
    Identifies files that need upgrading (better codec, resolution, audio, subtitles).

.DESCRIPTION
    • Walks every file under the supplied root path.
    • Calls MediaInfo-CLI to extract detailed metadata: codec, container, resolution,
      audio tracks, and subtitle tracks.
    • Filters results based on user-specified criteria (codec, resolution, missing
      audio/subtitles).
    • Builds a hierarchical object that mirrors the directory structure.
    • Outputs a structured JSON file with files that match the filter criteria,
      organized by folder path, making it easy to identify which Series/Movies
      need quality upgrades or better localized audio/subtitles.

.PARAMETER RootPath
    The folder to start scanning (e.g. V:\Series\).

.PARAMETER MediaInfoExe
    Full path to MediaInfo.exe.  If omitted the script searches the default
    install location and the system PATH.

.PARAMETER FilterCodecs
    Array of codecs to filter FOR (files with these codecs are included).
    Example: @('H.264', 'MPEG-2 Video', 'AV1')
    If omitted, all codecs except H.265/HEVC and AV1 are included.

.PARAMETER ExcludeCodecs
    Array of codecs to exclude (files with these codecs are skipped).
    Example: @('H.265', 'HEVC')
    Default: @('H.265', 'HEVC', 'AV1') to skip modern codecs.

.PARAMETER MinResolution
    Minimum resolution to include. Format: '1080p', '720p', '480p', etc.
    Files below this resolution are included (for upgrading).

.PARAMETER RequireAudio
    If $true, includes files with NO audio tracks.

.PARAMETER RequireSubtitles
    If $true, includes files with NO subtitle tracks.

.PARAMETER StatusFile
    Path to JSON file tracking processed folders (for resumable scanning).

.PARAMETER JsonOut
    Path to output JSON file with filtered results.

.EXAMPLE
    # Find all files with H.264 that need better audio/subtitles
    .\Filter-MediaQuality.ps1 -RootPath 'V:\Series\' -RequireAudio $true -RequireSubtitles $true

    # Find all low-resolution files
    .\Filter-MediaQuality.ps1 -RootPath 'V:\Films\' -MinResolution '720p'

    # Find specific codec files
    .\Filter-MediaQuality.ps1 -RootPath 'V:\Series\' -FilterCodecs @('H.264', 'MPEG-2')
#>
#Requires -Version 7.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string] $RootPath,

    [string] $MediaInfoExe = $null,
    [int]    $MaxDepth     = 0,
    
    # Filter parameters
    [string[]] $FilterCodecs    = $null,
    [string[]] $ExcludeCodecs   = @('H.265', 'HEVC', 'AV1'),
    [string]   $MinResolution   = $null,
    [bool]     $RequireAudio    = $false,
    [bool]     $RequireSubtitles = $false,
    
    # Output paths
    [string] $StatusFile   = (Join-Path $PWD.Path 'FilterMediaQualityStatus.json'),
    [string] $JsonOut      = (Join-Path $PWD.Path 'FilteredMediaQuality.json')
)

function Write-DebugInfo { param([string] $Message) if ($PSBoundParameters.ContainsKey('Verbose') -or $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Verbose')) { Write-Verbose $Message } }

function Get-MediaInfoPath {
    [OutputType([string])]
    param([string]$MediaInfoExe)

    if ($MediaInfoExe -and (Test-Path $MediaInfoExe -PathType Leaf)) {
        return $MediaInfoExe
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
    $rawOutput    = (& $mediaInfoExe --Output=XML $FilePath 2>&1) -join "`n"

    if ($LASTEXITCODE -ne 0) {
        throw "MediaInfo exited with code $LASTEXITCODE for file: $FilePath"
    }

    try {
        $doc = [xml]$rawOutput
        return , $doc
    }
    catch {
        throw "Failed to parse MediaInfo XML output: $_"
    }
}

# Extract comprehensive MediaInfo from XML
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
    $audioTracks  = $xml.SelectNodes('//mi:track[@type="Audio"]', $ns)
    $subtitleTracks = $xml.SelectNodes('//mi:track[@type="Text"]', $ns)

    # General properties
    $fileExtensionNode = if ($generalTrack) { $generalTrack.SelectSingleNode('mi:FileExtension', $ns) } else { $null }
    $fileExtension = if ($fileExtensionNode) { $fileExtensionNode.InnerText } else { $null }

    # Video properties
    $videoCountNode = if ($generalTrack) { $generalTrack.SelectSingleNode('mi:VideoCount', $ns) } else { $null }
    $videoCount = if ($videoCountNode) { [int]$videoCountNode.InnerText } else { 0 }
    $hasVideo = $videoCount -gt 0

    $videoCodecNode = if ($videoTrack) { $videoTrack.SelectSingleNode('mi:Format', $ns) } else { $null }
    $videoCodec = if ($videoCodecNode) { $videoCodecNode.InnerText } else { $null }

    $widthNode = if ($videoTrack) { $videoTrack.SelectSingleNode('mi:Width', $ns) } else { $null }
    $heightNode = if ($videoTrack) { $videoTrack.SelectSingleNode('mi:Height', $ns) } else { $null }
    
    $width = if ($widthNode) { [int]$widthNode.InnerText } else { $null }
    $height = if ($heightNode) { [int]$heightNode.InnerText } else { $null }
    
    $resolution = if ($height) { "$($width)x$($height)" } else { $null }

    # Audio properties
    $audioCount = $audioTracks.Count
    $audioCodecs = @()
    $audioLanguages = @()
    
    foreach ($audioTrack in $audioTracks) {
        $codecNode = $audioTrack.SelectSingleNode('mi:Format', $ns)
        if ($codecNode) { $audioCodecs += $codecNode.InnerText }
        
        $langNode = $audioTrack.SelectSingleNode('mi:Language', $ns)
        if ($langNode) { $audioLanguages += $langNode.InnerText }
    }

    # Subtitle properties
    $subtitleCount = $subtitleTracks.Count
    $subtitleLanguages = @()
    
    foreach ($subTrack in $subtitleTracks) {
        $langNode = $subTrack.SelectSingleNode('mi:Language', $ns)
        if ($langNode) { $subtitleLanguages += $langNode.InnerText }
    }

    [PSCustomObject]@{
        FileExtension     = $fileExtension
        HasVideo          = $hasVideo
        VideoCodec        = if ($hasVideo) { $videoCodec } else { $null }
        Resolution        = if ($hasVideo) { $resolution } else { $null }
        Width             = $width
        Height            = $height
        AudioCount        = $audioCount
        AudioCodecs       = $audioCodecs
        AudioLanguages    = $audioLanguages
        SubtitleCount     = $subtitleCount
        SubtitleLanguages = $subtitleLanguages
    }
}

# Determine if resolution meets minimum threshold
function Test-ResolutionFilter {
    param(
        [string]$CurrentResolution,
        [string]$MinResolution
    )

    if (-not $MinResolution -or -not $CurrentResolution) { return $true }

    # Parse minimum resolution (e.g., "720p" -> 720)
    $minHeight = [int]($MinResolution -replace '[^0-9]', '')
    
    # Parse current resolution (e.g., "1920x1080" -> 1080)
    $currentHeight = [int]($CurrentResolution -split 'x')[1]

    # Include if current is BELOW minimum (needs upgrade)
    return $currentHeight -lt $minHeight
}

# Determine if file matches filter criteria
function Test-FileQualityFilter {
    param(
        [PSCustomObject]$MediaInfo,
        [string[]]$FilterCodecs,
        [string[]]$ExcludeCodecs,
        [string]$MinResolution,
        [bool]$RequireAudio,
        [bool]$RequireSubtitles
    )

    # Must have video
    if (-not $MediaInfo.HasVideo) { return $false }

    # Codec filters
    if ($ExcludeCodecs -and $MediaInfo.VideoCodec) {
        foreach ($codec in $ExcludeCodecs) {
            if ($MediaInfo.VideoCodec -like "*$codec*") { return $false }
        }
    }

    if ($FilterCodecs) {
        $codecMatches = $false
        foreach ($codec in $FilterCodecs) {
            if ($MediaInfo.VideoCodec -like "*$codec*") { $codecMatches = $true; break }
        }
        if (-not $codecMatches) { return $false }
    }

    # Resolution filter (include if BELOW minimum)
    if ($MinResolution -and -not (Test-ResolutionFilter -CurrentResolution $MediaInfo.Resolution -MinResolution $MinResolution)) {
        return $false
    }

    # Audio filter (include if NO audio)
    if ($RequireAudio -and $MediaInfo.AudioCount -gt 0) {
        return $false
    }

    # Subtitle filter (include if NO subtitles)
    if ($RequireSubtitles -and $MediaInfo.SubtitleCount -gt 0) {
        return $false
    }

    return $true
}

# Build tree structure and collect filtered files
function Build-FilteredTree {
    param([string] $Root, [int] $MaxDepth = 0)

    $rootNode = [pscustomobject]@{ 
        Name = Split-Path $Root -Leaf
        FullPath = $Root
        Files = @()
        Subfolders = @()
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push([pscustomobject]@{ Node = $rootNode; Path = $Root; Depth = 1 })

    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $node = $frame.Node
        $path = $frame.Path
        $depth = $frame.Depth

        if ($ProcessedFolders -contains $path) {
            Write-Host "⏭️  SKIPPED (processed): $path" -ForegroundColor DarkGray
            continue
        }

        Write-Host "`nScanning: $path" -ForegroundColor Yellow

        try {
            $files = Get-ChildItem -Path $path -File -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to list files in $path : $_"
            $files = @()
        }

        foreach ($f in $files) {
            try {
                $mediaInfo = Get-MediaInfoPropertiesFromXml -FilePath $f.FullName -MediaInfoExe $MediaInfoExe

                # Check if file passes filters
                if (Test-FileQualityFilter -MediaInfo $mediaInfo `
                    -FilterCodecs $FilterCodecs `
                    -ExcludeCodecs $ExcludeCodecs `
                    -MinResolution $MinResolution `
                    -RequireAudio $RequireAudio `
                    -RequireSubtitles $RequireSubtitles) {

                    $displayCodec = if ($mediaInfo.VideoCodec) { $mediaInfo.VideoCodec } else { '<no codec>' }
                    $displayRes = if ($mediaInfo.Resolution) { $mediaInfo.Resolution } else { '<no video>' }
                    
                    Write-Host "  ✓ FILTERED: $($f.Name) | Resolution: $displayRes | Codec: $displayCodec | Audio: $($mediaInfo.AudioCount) | Subs: $($mediaInfo.SubtitleCount)" -ForegroundColor Cyan

                    $node.Files += [pscustomobject]@{
                        FileName           = $f.Name
                        FullPath           = $f.FullName
                        Extension          = $f.Extension.TrimStart('.')
                        Container          = $mediaInfo.FileExtension
                        VideoCodec         = $mediaInfo.VideoCodec
                        Resolution         = $mediaInfo.Resolution
                        Width              = $mediaInfo.Width
                        Height             = $mediaInfo.Height
                        AudioCount         = $mediaInfo.AudioCount
                        AudioCodecs        = @($mediaInfo.AudioCodecs)
                        AudioLanguages     = @($mediaInfo.AudioLanguages)
                        SubtitleCount      = $mediaInfo.SubtitleCount
                        SubtitleLanguages  = @($mediaInfo.SubtitleLanguages)
                        Reason             = Get-FilterReason -MediaInfo $mediaInfo -MinResolution $MinResolution -RequireAudio $RequireAudio -RequireSubtitles $RequireSubtitles
                    }
                }
            }
            catch {
                Write-Warning "Failed to process '$($f.FullName)': $_"
            }
        }

        if ($MaxDepth -le 0 -or $depth -lt $MaxDepth) {
            try {
                $subs = Get-ChildItem -Path $path -Directory -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Failed to list subfolders in $path : $_"
                $subs = @()
            }

            foreach ($s in $subs) {
                $childNode = [pscustomobject]@{
                    Name = $s.Name
                    FullPath = $s.FullPath
                    Files = @()
                    Subfolders = @()
                }
                $node.Subfolders += $childNode
                $stack.Push([pscustomobject]@{ Node = $childNode; Path = $s.FullName; Depth = $depth + 1 })
            }
        }

        $ProcessedFolders += $path
        Save-Status
    }

    return $rootNode
}

function Get-FilterReason {
    param(
        [PSCustomObject]$MediaInfo,
        [string]$MinResolution,
        [bool]$RequireAudio,
        [bool]$RequireSubtitles
    )

    $reasons = @()

    if ($MediaInfo.VideoCodec -match 'H\.264|MPEG-2') {
        $reasons += "Codec: $($MediaInfo.VideoCodec) (older codec)"
    }

    if ($MinResolution -and $MediaInfo.Height -lt [int]($MinResolution -replace '[^0-9]', '')) {
        $reasons += "Resolution: $($MediaInfo.Resolution) (below $MinResolution)"
    }

    if ($RequireAudio -and $MediaInfo.AudioCount -eq 0) {
        $reasons += "No audio tracks"
    }

    if ($RequireSubtitles -and $MediaInfo.SubtitleCount -eq 0) {
        $reasons += "No subtitles"
    }

    return $reasons -join ' | '
}

function Save-Status {
    $payload = [pscustomobject]@{ ProcessedFolders = $ProcessedFolders }
    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $StatusFile -Encoding UTF8
}

function Measure-TreeFilesCount {
    param([pscustomobject] $Node)
    $count = 0
    if ($Node.Files) { $count += ($Node.Files).Count }
    if ($Node.Subfolders) {
        foreach ($s in $Node.Subfolders) { $count += Measure-TreeFilesCount -Node $s }
    }
    return $count
}

# Initialize
Set-StrictMode -Version Latest

$ProcessedFolders = @()
if (Test-Path $StatusFile) {
    try {
        $status = Get-Content -Raw -Path $StatusFile | ConvertFrom-Json -ErrorAction Stop
        if ($status.ProcessedFolders) { $ProcessedFolders = [System.Collections.ArrayList]@($status.ProcessedFolders) }
    }
    catch {
        Write-Warning "Failed to read status file '${StatusFile}': $_. Starting fresh."
        $ProcessedFolders = @()
    }
} else {
    $ProcessedFolders = @()
}

$MediaInfoExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
Write-Host "Using MediaInfo: $MediaInfoExe" -ForegroundColor Cyan

# Display filter parameters
Write-Host "`n=== Filter Parameters ===" -ForegroundColor Cyan
Write-Host "Codec Filter       : $(if ($FilterCodecs) { $FilterCodecs -join ', ' } else { 'All codecs (except excluded)' })"
Write-Host "Exclude Codecs     : $($ExcludeCodecs -join ', ')"
Write-Host "Min Resolution     : $(if ($MinResolution) { $MinResolution } else { 'Any' })"
Write-Host "Require Audio      : $RequireAudio (include files with NO audio)"
Write-Host "Require Subtitles  : $RequireSubtitles (include files with NO subtitles)"

Write-Host "`n=== Starting scan ===" -ForegroundColor Cyan
$rootResolved = (Resolve-Path $RootPath).Path
$tree = Build-FilteredTree -Root $rootResolved -MaxDepth $MaxDepth

try {
    $tree | ConvertTo-Json -Depth 99 | Set-Content -Path $JsonOut -Encoding UTF8
    Write-Host "`n✅ Filtered results written to $JsonOut" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to write JSON: $_"
}

$fileCount = Measure-TreeFilesCount -Node $tree
$folderCount = ($ProcessedFolders | Measure-Object).Count

Write-Host "`n=== Scan Completed ===" -ForegroundColor Cyan
Write-Host "Folders processed      : $folderCount"
Write-Host "Filtered files found   : $fileCount"
Write-Host "`nYou may re-run this script; it will resume from last saved folder." -ForegroundColor Yellow
