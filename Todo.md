# Overview

These are features and bugfixes that need implementing.

## Completed Features

- ✅ Machine readable Output `ComparisonResult.csv` from `Compare-MediaInfo.ps1` to feed `Clean-HandBrakeBackups.ps1` as working list, where passed
- ✅ `Clean-HandBrakeBackups.ps1 -DryRun $true` to preview deletions
- ✅ `Clean-HandBrakeBackups.ps1 -FilterList '.\ComparisonResult.csv'` to permanently delete verified backups (uses output from `Compare-MediaInfo.ps1`)
- ✅ `Clean-HandBrakeBackups.ps1` to permanently delete all backups
- ✅ A download utilities script (`Get-UtilityTools.ps1`) that downloads HandBrake CLI and MediaInfo CLI into project subfolders
- ✅ Latest version detection for HandBrake and MediaInfo (`-UseLatest` flag)
- ✅ A Public domain, free of use, etc video file `Demo_wqhd_h264.mp4` in non-h265 mkv for testing and demo run
- ✅ Master orchestration script (`Invoke-MediaPipeline.ps1`) that automates the complete workflow:
  - Full automatic mode (all stages)
  - Stage-specific modes (Scan, Encode, QA, Cleanup)
  - Interactive mode with user confirmation between stages
  - Centralized logging
  - Dry-run preview mode for cleanup stage
  - Tool prerequisite validation

## Known Gaps & Recommendations

See `PIPELINE_GAPS.md` for:

- Identified implementation gaps in existing scripts
- Severity classification and impact analysis
- Recommendations for improvements
- Testing checklist before production use
- Priority order for fixes

**CRITICAL:** Exit code standardization needed in `Scan-MediaInfo.ps1` and `Run-HandBrakeCLI.ps1` before using Full pipeline mode.

## Future Features / Enhancements

- Complete resume/checkpoint implementation (skeleton in place)
- Shared utility module for tool discovery functions
- Configuration profiles for different encoding scenarios
- Email/Slack notifications on pipeline completion/failure
- Performance metrics and timing reports
- Integration with external scheduling tools (Windows Task Scheduler)
