# VideoWalkerConverter

![PowerShell](https://img.shields.io/badge/PowerShell-7.1%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)

A PowerShell-based solution for batch video transcoding with intelligent codec detection and resumable operations. Automatically scans your media library, identifies files that need re-encoding, and efficiently converts them to modern codecs using HandBrake CLI.

## 📋 Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Scripts](#scripts)
- [Configuration](#configuration)
- [Output Files](#output-files)
- [Project Structure](#project-structure)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## ✨ Features

- **Intelligent Codec Detection**: Uses MediaInfo CLI to analyze container formats and video codecs
- **Resumable Operations**: Maintains persistent status files so you can safely resume interrupted scans or encoding sessions
- **Batch Processing**: Recursively walks entire directory trees and processes all files
- **Hardware Acceleration**: Supports Intel QSV hardware acceleration for faster encoding (configurable)
- **Progress Tracking**: Real-time progress bars and status updates throughout the conversion process
- **CSV Queue Management**: Generates organized encoding queues with detailed file information
- **JSON Hierarchical Output**: Creates structured JSON representation of your media library
- **Debug Mode**: Optional command logging for troubleshooting and manual intervention
- **Flexible Configuration**: Easily adjustable quality levels and encoding parameters

## 📦 Prerequisites

- **PowerShell 7.1+** – Core requirement
- **HandBrake CLI** – Video transcoding engine
- **MediaInfo CLI** – Video codec and container format detection
- **Windows OS** – Tested on Windows 10/11

### Optional
- **Intel QSV Hardware** – For hardware-accelerated encoding (falls back to software encoding if unavailable)

## 🚀 Installation

### 1. Clone or Download Repository
```powershell
git clone https://github.com/yourusername/VideoWalkerConverter.git
cd VideoWalkerConverter
```

### 2. Install HandBrake CLI
Download from [HandBrake.fr](https://handbrake.fr/downloads.php) or extract the included portable version.

Note the installation path, e.g.:
```
C:\Program Files\HandBrake\HandBrakeCLI.exe
V:\HandBrakeCLI-1.11.1-win-x86_64\HandBrakeCLI.exe
```

### 3. Install MediaInfo CLI
Download from [MediaInfo.net](https://mediaarea.net/en/MediaInfo/Download/Windows) or use the included version.

Note the installation path, e.g.:
```
V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe
```

### 4. Set PowerShell Execution Policy (if needed)
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Unrestricted
```

## ⚡ Quick Start

### Step 1: Scan Your Media Library
Scan a folder to detect files needing re-encoding:

```powershell
.\Scan-MediaInfo.ps1 -RootPath 'V:\Series\' -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe'
```

This creates:
- `MediaInfoTree.json` – Hierarchical structure of your library
- `HandBrakeQueue.csv` – List of files to encode
- `ScanMediaInfoStatus.json` – Status tracking for resumable scans

### Step 2: Review the Queue
Inspect `HandBrakeQueue.csv` to verify which files will be converted.

### Step 3: Transcode Files
Execute the conversion:

```powershell
.\Run-HandBrakeCLI.ps1 -CsvPath '.\HandBrakeQueue.csv' -HandBrakePath 'V:\HandBrakeCLI-1.11.1-win-x86_64\HandBrakeCLI.exe'
```

Monitor progress and check `HandBrakeStatus.json` for real-time status.

### Step 4: Manually Verify Conversions (IMPORTANT)
**Before cleanup**, you must manually verify the converted files:
- Play a sample of converted `.mkv` files in your media player
- Verify video, audio, and subtitle streams are intact
- Compare at least 5-10 files to catch potential issues
- Use `MediaInfo.exe` to compare technical properties between backup and output

See **[No Post-Encoding Quality Assurance](#no-post-encoding-quality-assurance)** section for detailed verification steps.

### Step 5: Clean Up Backup Files
Once you've verified conversions are valid, run the cleanup script to delete backup files:

```powershell
.\Clean-HandBrakeBackups.ps1
```

This script reads `HandBrakeConversions.csv` (created by the encoder) and safely deletes only the `*_bak.*` files that have been successfully converted.

## 📖 Usage

### Scanning with Resume Capability
```powershell
# Initial scan
.\Scan-MediaInfo.ps1 -RootPath 'V:\Films\' `
  -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe'

# Resume after interruption - automatically picks up where it left off
.\Scan-MediaInfo.ps1 -RootPath 'V:\Films\' `
  -MediaInfoExe 'V:\MediaInfo_CLI_26.05_Windows_x64\MediaInfo.exe'
```

### Transcoding with Custom Quality
```powershell
# High quality (quality level 18, near-lossless)
.\Run-HandBrakeCLI.ps1 -CsvPath '.\HandBrakeQueue.csv' -QualityLevel 18

# Faster encoding, slightly lower quality (quality level 22)
.\Run-HandBrakeCLI.ps1 -CsvPath '.\HandBrakeQueue.csv' -QualityLevel 22

# Software encoding (no hardware acceleration)
.\Run-HandBrakeCLI.ps1 -CsvPath '.\HandBrakeQueue.csv' -UseQSV $false
```

### Debug Mode
```powershell
# Print exact HandBrake commands before execution
.\Run-HandBrakeCLI.ps1 -CsvPath '.\HandBrakeQueue.csv' -DebugCommands

# Verbose output for detailed logging
.\Scan-MediaInfo.ps1 -RootPath 'V:\Series\' -Verbose
```

## ⚠️ Known Limitations & Disclaimers

### No Post-Encoding Quality Assurance
**IMPORTANT:** This script does **not** perform QA validation after successful encoding. While HandBrake reports `returnCode 0` for success, some files may encode without visible errors but lack the video stream in the output file—despite the video track being present in the source.

**How the Script Works:**
The script renames your original file to a backup (`*_bak.*`) before encoding, then converts that backup to the output `.mkv` file. If conversion reports success (returnCode 0), both files are kept.

**Observed Issues:**
- Successful encoding (returnCode 0) but missing video stream in output file
- HandBrake UI with similar parameters produces correct results
- Recommend spot-checking converted files, especially with unusual formats or output file sizes

**How to Verify Conversions:**
1. After conversion completes, the original is saved as `*_bak.*` and the converted output is `.mkv`
2. **Compare the backup against the output** using a media player:
   - Play both files and verify the output has all expected video/audio streams
   - Check duration, frame count, and visual quality match
   - Use MediaInfo CLI to compare technical properties: `MediaInfo.exe backup_file.ext` vs `MediaInfo.exe output_file.mkv`
3. Only delete the backup (`*_bak.*`) files after confirming the conversion is valid

**Recommendations:**
- Manually verify a sample of conversions before running large batch operations
- Compare at least 5-10 diverse files to catch potential issues
- Use the `*_bak.*` files to verify output integrity
- Use HandBrake UI for testing parameters on problematic files
- Keep backup files until you've verified the entire batch is correct

### Output Size vs. Quality Trade-offs
This script prioritizes **quality preservation** over file size optimization. Intel QSV hardware acceleration is enabled by default, which may result in larger output files compared to software encoding.

**Example Quality Level Impact:**
| Quality Level | Input Size | Output Size | Notes |
|---------------|-----------|-------------|-------|
| 18 (near-lossless) | 1.5 GiB | 1.7 GiB | Larger output, highest quality |
| 22 (balanced) | 1.5 GiB | 433 MiB | Significant space savings, good quality |
| 24+ | 1.5 GiB | ~300 MiB | Smaller files, noticeable quality loss |

To reduce output size:
- Increase `QualityLevel` (higher = smaller file)
- Disable hardware acceleration: `-UseQSV $false`
- Test thoroughly before batch processing

## 🔧 Scripts

### `Scan-MediaInfo.ps1`
Recursively scans a folder tree, extracts codec information, and generates encoding queue.

**Parameters:**
- `RootPath` (required) – Root folder to scan, e.g., `V:\Series\`
- `MediaInfoExe` – Path to MediaInfo.exe (auto-detected if omitted)
- `StatusFile` – Path to persistence file (default: `ScanMediaInfoStatus.json`)
- `JsonOut` – Output JSON file (default: `MediaInfoTree.json`)
- `CsvOut` – Output CSV file (default: `HandBrakeQueue.csv`)

**Features:**
- Persistent scanning with resume capability
- Generates hierarchical JSON of directory structure
- Detects outdated codecs and formats
- Creates CSV queue for encoding

### `Run-HandBrakeCLI.ps1`
Reads encoding queue and executes HandBrake transcoding with progress tracking.

**Parameters:**
- `CsvPath` – Path to HandBrakeQueue.csv (default: same folder as script)
- `HandBrakePath` – Path to HandBrakeCLI.exe (auto-detected if omitted)
- `QualityLevel` – Quality setting 0-51 (default: 18, typical: 16-22)
- `UseQSV` – Enable Intel QSV acceleration (default: $true)
- `DebugCommands` – Print commands before execution (default: $false)

**Features:**
- Real-time progress tracking
- Persistent status with Completed/Failed/Skipped tracking
- Safe resume after interruption or crash
- Detailed status JSON output

### `Test-MediaInfo.ps1`
Testing utility for verifying MediaInfo functionality and troubleshooting.

### `Clean-HandBrakeBackups.ps1` (Cleanup Utility)
Safely deletes backup files after manual verification.

**Parameters:**
- `ConversionsFile` – Path to HandBrakeConversions.csv (default: same folder as script)
- `DryRun` – Preview deletions without removing files (default: $false)

**Features:**
- Reads `HandBrakeConversions.csv` generated by `Run-HandBrakeCLI.ps1`
- Only deletes `*_bak.*` files associated with successful conversions
- Optional dry-run mode to preview what will be deleted
- Prevents accidental deletion of unrelated files

**Recommended Workflow:**
1. Run `Run-HandBrakeCLI.ps1` to encode files (creates backups and `HandBrakeConversions.csv`)
2. Manually verify converted `.mkv` files are valid
3. Run `Clean-HandBrakeBackups.ps1 -DryRun $true` to preview deletions
4. Run `Clean-HandBrakeBackups.ps1` to permanently delete verified backups

## ⚙️ Configuration

### Quality Levels
- `16-18`: High quality, near-lossless (slower encoding)
- `20-22`: Balanced quality and speed
- `24+`: Smaller files, lower quality (faster encoding)

### Hardware Acceleration
Hardware acceleration significantly speeds up encoding. Supported options:
- `qsv_h265` – Intel QSV H.265 (recommended)
- `av1_qsv` – Intel QSV AV1 (newer codec, slower)
- `x265` – Software H.265 (fallback)
- `av1` – Software AV1 (fallback)

Disable QSV if you encounter compatibility issues:
```powershell
.\Run-HandBrakeCLI.ps1 -UseQSV $false
```

## 📄 Output Files

| File | Description |
|------|-------------|
| `MediaInfoTree.json` | Hierarchical JSON representation of scanned directory structure |
| `HandBrakeQueue.csv` | CSV list of files to encode with details (path, codec, container) |
| `ScanMediaInfoStatus.json` | Scan progress tracking for resumable operations |
| `HandBrakeStatus.json` | Encoding progress with Completed/Failed/Skipped counts |
| `HandBrakeConversions.csv` | Helper file: list of BackupFile/OutputFile pairs for cleanup script |

## 📁 Project Structure

```
VideoWalkerConverter/
├── Run-HandBrakeCLI.ps1          # Main encoding script
├── Scan-MediaInfo.ps1             # Media library scanner
├── Test-MediaInfo.ps1             # Testing utility
├── ReadMe.md                       # This file
├── HandBrakeCLI-1.11.1-win-x86_64/  # Portable HandBrake (optional)
├── MediaInfo_CLI_26.05_Windows_x64/ # Portable MediaInfo (optional)
├── HandBrakeQueue.csv             # Generated: encoding queue
├── MediaInfoTree.json             # Generated: library structure
├── ScanMediaInfoStatus.json       # Generated: scan status
├── HandBrakeStatus.json           # Generated: encoding status
└── Films/, Series/, Recordings/   # Your media folders
```

## 🐛 Troubleshooting

### HandBrakeCLI Not Found
Specify the full path explicitly:
```powershell
.\Run-HandBrakeCLI.ps1 -HandBrakePath 'C:\path\to\HandBrakeCLI.exe'
```

### MediaInfo Not Found
Specify the full path explicitly:
```powershell
.\Scan-MediaInfo.ps1 -RootPath 'V:\Series\' -MediaInfoExe 'C:\path\to\MediaInfo.exe'
```

### Execution Policy Error
Run with bypass flag:
```powershell
powershell -ExecutionPolicy Bypass -File .\Scan-MediaInfo.ps1 -RootPath 'V:\Series\'
```

### Encoding Fails on Specific Files
Use debug mode to see exact commands:
```powershell
.\Run-HandBrakeCLI.ps1 -DebugCommands
```

Then manually test the command or adjust quality settings.

### Hardware Acceleration Not Working
Fall back to software encoding:
```powershell
.\Run-HandBrakeCLI.ps1 -UseQSV $false
```

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Make your changes
4. Test thoroughly
5. Commit with clear messages
6. Push to the branch
7. Open a Pull Request

## 📄 License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-v3)** – see the LICENSE file for details.

**Why AGPL-v3?**
- ✅ Copyleft: Requires modifications to be shared
- ✅ No Commercial Use: Prevents commercial exploitation without permission
- ✅ Network Copyleft: Includes provisions for network-accessed code

For alternative licensing arrangements, please contact the project maintainer.

---

**Questions or Issues?** Please open an issue on GitHub!

**Made with ❤️ for video enthusiasts**
