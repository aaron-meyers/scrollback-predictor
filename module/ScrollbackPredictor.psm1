using namespace System.Management.Automation
using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

# Register the predictor subsystem
$predictor = [ScrollbackPredictor.ScrollbackPredictor]::new()
[SubsystemManager]::RegisterSubsystem([SubsystemKind]::CommandPredictor, $predictor)

# Capture output via transcript file monitoring.
# PowerShell 7 doesn't route implicit output through Out-Default function overrides,
# so we start a transcript and read new content at each prompt.

$transcriptPath = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    "ScrollbackPredictor_$PID.log"
)
$global:__ScrollbackTranscriptPath = $transcriptPath
$global:__ScrollbackLastPosition = 0

try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
} catch {
    # Transcript may already be running; try to stop and restart
    try { Stop-Transcript | Out-Null } catch { }
    Start-Transcript -Path $transcriptPath -Force | Out-Null
}

# Save the original prompt
$originalPrompt = $function:Global:prompt

function Global:prompt {
    # Read new transcript content since last check
    try {
        $path = $global:__ScrollbackTranscriptPath
        if ($path -and [System.IO.File]::Exists($path)) {
            $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $len = $fs.Length
                $lastPos = $global:__ScrollbackLastPosition
                if ($len -gt $lastPos) {
                    $fs.Position = $lastPos
                    $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                    try {
                        $newText = $reader.ReadToEnd()
                        $global:__ScrollbackLastPosition = $len
                        foreach ($line in $newText -split '\r?\n') {
                            if ($line -and $line.Trim()) {
                                [ScrollbackPredictor.ScrollbackIndex]::AddLine($line)
                            }
                        }
                    } finally {
                        $reader.Dispose()
                    }
                }
            } finally {
                $fs.Dispose()
            }
        }
    } catch { }

    if ($script:originalPrompt) {
        & $script:originalPrompt
    } else {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
}

function Clear-ScrollbackIndex {
    <#
    .SYNOPSIS
    Clears all tokens from the scrollback index.
    #>
    [ScrollbackPredictor.ScrollbackIndex]::Clear()
    Write-Host "Scrollback index cleared."
}

function Get-ScrollbackIndexCount {
    <#
    .SYNOPSIS
    Returns the number of tokens currently in the scrollback index.
    #>
    [ScrollbackPredictor.ScrollbackIndex]::Count
}

$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    # Unregister predictor on module removal
    try {
        [SubsystemManager]::UnregisterSubsystem([SubsystemKind]::CommandPredictor, [guid]'f3b3e7a0-6c1a-4e2d-9f5b-8a7c3d2e1f00')
    } catch { }

    # Stop transcript and clean up
    try { Stop-Transcript | Out-Null } catch { }
    $path = $global:__ScrollbackTranscriptPath
    if ($path -and [System.IO.File]::Exists($path)) {
        try { Remove-Item $path -Force } catch { }
    }

    # Restore original prompt
    if ($script:originalPrompt) {
        $function:Global:prompt = $script:originalPrompt
    } else {
        Remove-Item Function:\prompt -ErrorAction SilentlyContinue
    }

    # Clean up global variables
    Remove-Variable -Name __ScrollbackTranscriptPath -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name __ScrollbackLastPosition -Scope Global -ErrorAction SilentlyContinue
}
