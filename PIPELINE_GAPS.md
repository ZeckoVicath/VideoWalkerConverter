# Media Pipeline - Implementation Gaps & Recommendations

## Summary

Created `Invoke-MediaPipeline.ps1` as the master orchestration script. This document identifies gaps in existing scripts that affect pipeline robustness and provides implementation recommendations.

---

## Critical Gaps Identified

### 1. **Inconsistent Exit Code Handling**

**Severity: HIGH**

**Gap:** Not all scripts consistently use exit codes (0 = success, 1 = failure)

- `Scan-MediaInfo.ps1`: No explicit exit code detected
- `Run-HandBrakeCLI.ps1`: No explicit exit code detected  
- `Compare-MediaInfo.ps1`: Uses exit codes (✓)
- `Clean-HandBrakeBackups.ps1`: Uses exit codes (✓)
- `Get-UtilityTools.ps1`: Uses exit codes (✓)

**Impact:** Orchestration script cannot reliably detect failure and halt pipeline

**Recommendation:**

```powershell
# Add to end of Scan-MediaInfo.ps1 and Run-HandBrakeCLI.ps1:
exit $failureCount  # or: exit ([int]($failureCount -gt 0))
```

**Priority:** CRITICAL - fix before using Full mode pipeline

---

### 2. **Working Directory Assumptions**

**Severity: MEDIUM**

**Gap:** Scripts use `$PWD` vs `$PSScriptRoot` inconsistently

- `Scan-MediaInfo.ps1`: Uses `$PWD` for output paths (default parameters)
- `Run-HandBrakeCLI.ps1`: Uses `$PSScriptRoot` for input
- `Compare-MediaInfo.ps1`: Reads from `$PSScriptRoot`
- `Clean-HandBrakeBackups.ps1`: Uses `$PSScriptRoot`

**Impact:** When orchestrator changes directory, some scripts may write outputs to unexpected locations

**Workaround in Invoke-MediaPipeline.ps1:**

```powershell
Push-Location $PipelineRoot
& $scriptPath -Parameters...
Pop-Location
```

**Recommendation:** Normalize all scripts to accept explicit output path parameters instead of using PWD

---

### 3. **Tool Path Discovery Fragmentation**

**Severity: MEDIUM**

**Gap:** Each script independently searches for MediaInfo/HandBrake exe

- `Scan-MediaInfo.ps1`: Has `Get-MediaInfoPath` function
- `Run-HandBrakeCLI.ps1`: Has `Get-HandBrakePath` function  
- `Compare-MediaInfo.ps1`: Has similar logic embedded
- `Clean-HandBrakeBackups.ps1`: Doesn't need tools

**Impact:** Redundant code, potential inconsistencies in tool discovery

**Current Workaround in Invoke-MediaPipeline.ps1:**

```powershell
$mediaInfoPath = Find-UtilityExecutable -ToolName 'MediaInfo'
```

**Recommendation:** Create shared utility module (e.g., `MediaPipelineUtils.psm1`) with tool discovery functions

---

### 4. **Logging Not Centralized**

**Severity: LOW**

**Gap:** Individual scripts don't write to central pipeline log

- Each script has its own console output
- No unified timestamp format
- Difficult to debug pipeline-wide issues

**Solution Implemented:**

```powershell
# In Invoke-MediaPipeline.ps1:
Write-Log -Message "..." -Level 'INFO'|'WARN'|'ERROR'|'SUCCESS'
```

**Note:** Script output still goes to console; centralized logging in orchestrator supplements this

---

### 5. **Resume/Checkpoint Capability Not Integrated**

**Severity: MEDIUM**

**Gap:** Individual scripts support resume (status JSON files) but orchestrator doesn't leverage it

- `Scan-MediaInfo.ps1`: Has `ScanMediaInfoStatus.json` for resume
- `Run-HandBrakeCLI.ps1`: Has `HandBrakeStatus.json` for resume
- Orchestrator doesn't read these files

**Impact:** Interrupting pipeline forces restart from beginning

**Recommendation:** Add parameter to orchestrator:

```powershell
-ResumeFrom 'encode' | 'scan' | 'qa'
```

*(Skeleton included but not fully implemented - see below)*

---

### 6. **Configuration Parameters Not Passed Through Pipeline**

**Severity: LOW**

**Gap:** Some script parameters aren't exposed at orchestration level

- `Scan-MediaInfo.ps1`: `-MaxDepth` parameter not exposed
- Quality settings tuning for different content types
- Custom output file names

**Recommendation:** Add optional parameter groups to `Invoke-MediaPipeline.ps1`:

```powershell
[Parameter(Mandatory=$false)]
[int]$ScanMaxDepth = 0,

[Parameter(Mandatory=$false)]
[string]$CustomQueueName = 'HandBrakeQueue.csv'
```

---

## Partial Implementation Notes

### Resume/Checkpoint Logic

The parameter `-ResumeFrom` is defined in `Invoke-MediaPipeline.ps1` but the logic to skip completed stages is a **TODO**:

```powershell
# TODO: Implement resume logic
if ($ResumeFrom) {
    # Skip stages completed before checkpoint
    # Example: if ResumeFrom='encode', skip Scan stage
}
```

**Recommendation:** Implement before using in production with large file sets

---

## Gap Severity Summary

| Severity | Count | Items |
| ---------- | ------- | ------- |
| CRITICAL | 1 | Exit code standardization |
| HIGH | 2 | Working directory assumptions, tool discovery fragmentation |
| MEDIUM | 2 | Checkpoint integration, config parameter passthrough |
| LOW | 1 | Centralized logging |

---

## Testing Checklist

Before using pipeline in production:

- [ ] Test Full mode with demo video file
- [ ] Verify exit codes from all stages  
- [ ] Test Interactive mode with user confirmations
- [ ] Test individual mode runs (Scan-only, Encode-only, etc.)
- [ ] Verify cleanup properly uses FilterList from QA stage
- [ ] Test DryRun mode without deleting files
- [ ] Verify log file generation and formatting
- [ ] Test with custom quality settings
- [ ] Test with UseLatestTools flag
- [ ] Verify tool discovery with/without environment variables

---

## Recommended Priority Order for Fixes

1. **IMMEDIATE:** Add explicit `exit` codes to `Scan-MediaInfo.ps1` and `Run-HandBrakeCLI.ps1`
2. **SOON:** Implement full resume/checkpoint logic in orchestrator
3. **NICE-TO-HAVE:** Create utility module for tool discovery
4. **FUTURE:** Add configuration profiles for different use cases (aggressive compression, fast transcode, archive quality, etc.)
