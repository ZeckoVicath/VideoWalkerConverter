<#
.SYNOPSIS
    Quick sanity‑check for MediaInfoCLI XML output.

.DESCRIPTION
    Executes MediaInfoCLI with the –Output=XML flag, makes sure the
    command succeeds, parses the XML, and writes the three properties
    (FileExtension, HasVideo, VideoCodec) to the console.  This lets you
    confirm that the CLI is reachable and that the XML structure matches
    the sample you posted.

.PARAMETER MediaInfoExe
    Full path to the MediaInfoCLI executable (e.g. C:\Tools\MediaInfo\MediaInfo.exe).

.PARAMETER FilePath
    Path to the media file you want to test.

.EXAMPLE
    . V:\Test‑MediaInfo.ps1 -MediaInfoExe "C:\Tools\MediaInfo\MediaInfo.exe" `
        -FilePath "V:\Series_M\One Pizza (1999)\Season 00\One Pizza - S00E01.mkv"
	pwsh -NoProfile -ExecutionPolicy Bypass -File .\Test-MediaInfo.ps1 `
		-FilePath 'V:\Series_M\One Pizza (1999) {tmdb-37854}\Season 00\One Pizza - S00E01.mkv' -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe' 
#>
#Requires -Version 7.1

# ─────────────────────────────────────────────
# Script Parameters
# ─────────────────────────────────────────────

param (
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$FilePath,

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$MediaInfoExe,

    [Parameter()]
    [switch]$DebugVerbose
)

# ─────────────────────────────────────────────
# Helper
# ─────────────────────────────────────────────

# Resolves the path to MediaInfoCLI executable
# Priority: explicit parameter > environment variable > system PATH
# Returns the resolved path or throws if not found
function Get-MediaInfoPath {
    [OutputType([string])]
    param(
        [string]$MediaInfoExe
    )

    # Check 1: Explicit path passed via -MediaInfoExe parameter
    if ($MediaInfoExe -and (Test-Path $MediaInfoExe -PathType Leaf)) {
        return $MediaInfoExe
    }

    # Check 2: Environment override (e.g. $env:MEDIAINFO_PATH = 'D:\tools\MediaInfo.exe')
    if ($env:MEDIAINFO_PATH -and (Test-Path $env:MEDIAINFO_PATH -PathType Leaf)) {
        return $env:MEDIAINFO_PATH
    }

    # Check 3: Fall back to whatever is on system $PATH
    $onPath = Get-Command -Name 'MediaInfo' -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }

    # Not found anywhere
    throw "MediaInfo CLI not found. Pass -MediaInfoExe, set `$env:MEDIAINFO_PATH, or add MediaInfo to `$PATH."
}

# ─────────────────────────────────────────────
# MediaInfo CLI Wrappers
# ─────────────────────────────────────────────
# These functions execute MediaInfo with different output formats (XML/JSON)
# and handle error checking. Each returns the parsed data structure.

# Executes MediaInfo with XML output and parses the result
# Returns an [xml] document object
function Invoke-MediaInfoXml {
    [CmdletBinding()]
    [OutputType([xml])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    # Resolve the MediaInfo executable path
    $mediaInfoExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
    
    # Execute MediaInfo with XML output, join array to single string
    $rawOutput    = (& $mediaInfoExe --Output=XML $FilePath 2>&1) -join "`n"

    # Check for execution errors
    if ($LASTEXITCODE -ne 0) {
        throw "MediaInfo exited with code $LASTEXITCODE for file: $FilePath"
    }

    # Parse the raw XML string to [xml] object
    try {
        $doc = [xml]$rawOutput
        return , $doc             # Unary comma prevents PowerShell enumerating XmlDocument child nodes
    }
    catch {
        throw "Failed to parse MediaInfo XML output: $_"
    }
}

# Executes MediaInfo with JSON output and parses the result
# Returns a PSCustomObject with media track information
function Invoke-MediaInfoJson {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    # Resolve the MediaInfo executable path
    $mediaInfoExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
    
    # Execute MediaInfo with JSON output, join array to single string
    $rawOutput    = (& $mediaInfoExe --Output=JSON $FilePath 2>&1) -join "`n"

    # Check for execution errors
    if ($LASTEXITCODE -ne 0) {
        throw "MediaInfo exited with code $LASTEXITCODE for file: $FilePath"
    }

    # Parse the raw JSON string to PowerShell object
    try {
        $rawOutput | ConvertFrom-Json -NoEnumerate
    }
    catch {
        throw "Failed to parse MediaInfo JSON output: $_"
    }
}

# ─────────────────────────────────────────────
# Parsers
# ─────────────────────────────────────────────
# These functions extract key media properties from the parsed output
# (FileExtension, HasVideo, VideoCodec) and return them as PSCustomObjects

# Parses XML output from MediaInfo to extract key video properties
# Uses XPath with namespace handling to locate General and Video tracks
# Returns: PSCustomObject with Source, FileExtension, HasVideo, VideoCodec
function Get-MediaInfoPropertiesFromXml {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    # Execute MediaInfo and get XML document
    $xml = Invoke-MediaInfoXml -FilePath $FilePath -MediaInfoExe $MediaInfoExe

    # Set up XML namespace manager for proper XPath queries
    $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('mi', 'https://mediaarea.net/mediainfo')

    # Query the General and Video tracks using namespace-aware XPath
    $generalTrack = $xml.SelectSingleNode('//mi:track[@type="General"]', $ns)
    $videoTrack   = $xml.SelectSingleNode('//mi:track[@type="Video"]',   $ns)

    # Extract file extension from General track
    $fileExtensionNode = if ($generalTrack) { $generalTrack.SelectSingleNode('mi:FileExtension', $ns) } else { $null }
    
    # Extract video count to determine if video stream exists
    $videoCountNode    = if ($generalTrack) { $generalTrack.SelectSingleNode('mi:VideoCount',    $ns) } else { $null }
    
    # Extract video codec format from Video track
    $videoCodecNode    = if ($videoTrack)   { $videoTrack.SelectSingleNode('mi:Format',         $ns) } else { $null }

    # Parse extracted values
    $fileExtension = if ($fileExtensionNode) { $fileExtensionNode.InnerText } else { $null }
    $videoCount    = if ($videoCountNode) { [int]$videoCountNode.InnerText } else { 0 }
    $hasVideo      = $videoCount -gt 0
    $videoCodec    = if ($videoCodecNode) { $videoCodecNode.InnerText } else { $null }

    # Return structured result
    [PSCustomObject]@{
        Source        = 'XML'
        FileExtension = $fileExtension
        HasVideo      = $hasVideo
        VideoCodec    = if ($hasVideo) { $videoCodec } else { $null }
    }
}

# Parses JSON output from MediaInfo to extract key video properties
# Navigates the media.track array structure to locate General and Video tracks
# Returns: PSCustomObject with Source, FileExtension, HasVideo, VideoCodec
function Get-MediaInfoPropertiesFromJson {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$MediaInfoExe
    )

    # Execute MediaInfo and get parsed JSON object
    $parsed = Invoke-MediaInfoJson -FilePath $FilePath -MediaInfoExe $MediaInfoExe
    $tracks = $parsed.media.track

    # Find General and Video tracks in the track array
    $generalTrack = $tracks | Where-Object { $_.'@type' -eq 'General' } | Select-Object -First 1
    $videoTrack   = $tracks | Where-Object { $_.'@type' -eq 'Video'   } | Select-Object -First 1

    # Extract properties from tracks
    $fileExtension = if ($generalTrack) { $generalTrack.FileExtension } else { $null }
    $videoCount    = if ($generalTrack) { [int]$generalTrack.VideoCount } else { 0 }
    $hasVideo      = $videoCount -gt 0
    $videoCodec    = if ($videoTrack) { $videoTrack.Format } else { $null }

    # Return structured result
    [PSCustomObject]@{
        Source        = 'JSON'
        FileExtension = $fileExtension
        HasVideo      = $hasVideo
        VideoCodec    = if ($hasVideo) { $videoCodec } else { $null }
    }
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

Set-StrictMode -Off   # Prevent StrictMode from masking real errors during debug
$ErrorActionPreference = 'Stop'

try {
    if ($DebugVerbose) {
        # ======== Debug Mode (Mutually Exclusive) ========
        Write-Host "`n[DEBUG MODE ENABLED]" -ForegroundColor Yellow
        
        # Step 1: Resolve MediaInfo executable
        Write-Host "`n[1] Resolving MediaInfo executable..." -ForegroundColor Yellow
        $resolvedExe = Get-MediaInfoPath -MediaInfoExe $MediaInfoExe
        Write-Host "    -> $resolvedExe" -ForegroundColor Green

        # Step 2: Run MediaInfo with XML output
        Write-Host "`n[2] Running MediaInfo --Output=XML..." -ForegroundColor Yellow
        $rawXml = & $resolvedExe --Output=XML $FilePath 2>&1
        Write-Host "    LASTEXITCODE : $LASTEXITCODE"
        Write-Host "    Output type  : $($rawXml.GetType().FullName)"
        Write-Host "    Output length: $($rawXml.Length) chars"
        Write-Host "    First 300 chars:`n$($rawXml[0..299] -join '')" -ForegroundColor DarkGray

        # Step 3: Parse XML
        Write-Host "`n[3] Casting raw output to [xml]..." -ForegroundColor Yellow
        [xml]$parsedXml = $rawXml
        Write-Host "    Root element : $($parsedXml.DocumentElement.Name)"

        # Step 4: Build namespace manager
        Write-Host "`n[4] Building namespace manager..." -ForegroundColor Yellow
        $ns = [System.Xml.XmlNamespaceManager]::new($parsedXml.NameTable)
        $ns.AddNamespace('mi', 'https://mediaarea.net/mediainfo')

        # Step 5: Select General track
        Write-Host "`n[5] Selecting General track..." -ForegroundColor Yellow
        $generalTrack = $parsedXml.SelectSingleNode('//mi:track[@type="General"]', $ns)
        Write-Host "    General track null? : $($null -eq $generalTrack)"

        # Step 6: Select Video track
        Write-Host "`n[6] Selecting Video track..." -ForegroundColor Yellow
        $videoTrack = $parsedXml.SelectSingleNode('//mi:track[@type="Video"]', $ns)
        Write-Host "    Video track null?   : $($null -eq $videoTrack)"

        # Step 7: Extract General track fields
        if ($null -ne $generalTrack) {
            Write-Host "`n[7] Reading General track fields..." -ForegroundColor Yellow
            Write-Host "    FileExtension : $($generalTrack.SelectSingleNode('mi:FileExtension', $ns)?.InnerText)"
            Write-Host "    VideoCount    : $($generalTrack.SelectSingleNode('mi:VideoCount',    $ns)?.InnerText)"
        }

        # Step 8: Run MediaInfo with JSON output
        Write-Host "`n[8] Running MediaInfo --Output=JSON..." -ForegroundColor Yellow
        $rawJson = & $resolvedExe --Output=JSON $FilePath 2>&1
        Write-Host "    LASTEXITCODE : $LASTEXITCODE"
        Write-Host "    Output type  : $($rawJson.GetType().FullName)"
        Write-Host "    First 300 chars:`n$($rawJson[0..299] -join '')" -ForegroundColor DarkGray

        # Step 9: Parse JSON
        Write-Host "`n[9] Parsing JSON..." -ForegroundColor Yellow
        $parsedJson = $rawJson | ConvertFrom-Json -NoEnumerate
        Write-Host "    media null?        : $($null -eq $parsedJson.media)"
        Write-Host "    track count        : $($parsedJson.media.track.Count)"
        Write-Host "    track @types       : $(($parsedJson.media.track | ForEach-Object { $_.'@type' }) -join ', ')"
    }
    else {
        # ======== Normal Mode (Mutually Exclusive) ========
        # Parse both XML and JSON to cross-validate results
        $xmlResult  = Get-MediaInfoPropertiesFromXml  -FilePath $FilePath -MediaInfoExe $MediaInfoExe
        $jsonResult = Get-MediaInfoPropertiesFromJson -FilePath $FilePath -MediaInfoExe $MediaInfoExe

        # Display XML parser result
        Write-Host "`n── XML Parser Result ──────────────────" -ForegroundColor Cyan
        $xmlResult  | Format-List

        # Display JSON parser result
        Write-Host "── JSON Parser Result ─────────────────" -ForegroundColor Cyan
        $jsonResult | Format-List

        # Side-by-side comparison
        Write-Host "── Side-by-side Comparison ────────────" -ForegroundColor Cyan
        @($xmlResult, $jsonResult) | Format-Table -AutoSize
    }
}
catch {
    Write-Error "Failed to process '$FilePath': $_"
    exit 1
}