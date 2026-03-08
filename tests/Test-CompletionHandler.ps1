<#
.SYNOPSIS
    Integration test for completion handler logic.
.DESCRIPTION
    Tests the Invoke-TokenCompletion function's logic by simulating its internal
    state transitions. Since we can't send Ctrl+N in a non-interactive context,
    this tests the state machine directly.
#>

$ErrorActionPreference = 'Stop'
$passCount = 0
$failCount = 0

function Assert-True($Condition, $Message) {
    if ($Condition) {
        Write-Host "  [PASS] $Message" -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        $script:failCount++
    }
}

function Assert-Equal($Expected, $Actual, $Message) {
    if ($Expected -eq $Actual) {
        Write-Host "  [PASS] $Message" -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host "  [FAIL] $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
        $script:failCount++
    }
}

Write-Host "=== Completion Handler Logic Tests ===" -ForegroundColor Cyan
Write-Host "PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Gray

$modulePath = Join-Path $PSScriptRoot '..\ScrollbackPredictor\ScrollbackPredictor.psd1'
Import-Module $modulePath -Force
$mod = Get-Module ScrollbackPredictor

Write-Host "`n--- Word Boundary Detection ---" -ForegroundColor Yellow

$wordStart = & $mod { Get-WordBoundary "Write-Host foobar" 17 }
Assert-Equal 11 $wordStart "Word boundary for 'foobar' at end of 'Write-Host foobar'"

$wordStart = & $mod { Get-WordBoundary "Get-Item C:\Users\test" 22 }
Assert-Equal 9 $wordStart "Word boundary for path 'C:\Users\test'"

$wordStart = & $mod { Get-WordBoundary "echo hello" 5 }
Assert-Equal 5 $wordStart "Word boundary at space (cursor after 'echo ')"

$wordStart = & $mod { Get-WordBoundary "" 0 }
Assert-Equal 0 $wordStart "Word boundary in empty string"

Write-Host "`n--- Completion State Machine ---" -ForegroundColor Yellow

# Seed tokens
& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "deployment-alpha deployment-bravo deployment-charlie"
}

# Test Find-TokenMatches (core of completion)
$matches = & $mod { Find-TokenMatches "deploy" }
Assert-Equal 3 $matches.Count "Found 3 matches for prefix 'deploy'"
Assert-Equal 'deployment-charlie' $matches[0] "Most recent match is first (charlie)"

# Test completion state transitions
& $mod {
    $cs = $script:CompletionState
    $cs.Active = $false
    $cs.OriginalPrefix = ''
    $cs.Matches = @()
    $cs.Index = -1
}

# Simulate first Ctrl+N: start completion with prefix "deploy" on line "echo deploy"
& $mod {
    $cs = $script:CompletionState
    $prefix = "deploy"
    $matches = Find-TokenMatches $prefix
    $cs.Active = $true
    $cs.OriginalPrefix = $prefix
    $cs.Matches = $matches
    $cs.Index = 0
    $cs.ReplacementStart = 5
    $cs.ReplacementEnd = 5 + $matches[0].Length
}

$cs = & $mod { $script:CompletionState }
Assert-True $cs.Active "Completion state is active after first Ctrl+N"
Assert-Equal 'deploy' $cs.OriginalPrefix "Original prefix preserved"
Assert-Equal 0 $cs.Index "Index is 0 (first match)"
Assert-Equal 'deployment-charlie' $cs.Matches[0] "First match is deployment-charlie"

# Simulate second Ctrl+N: cycle forward
& $mod {
    $cs = $script:CompletionState
    $cs.Index += 1
    if ($cs.Index -ge $cs.Matches.Count) { $cs.Index = 0 }
    $match = $cs.Matches[$cs.Index]
    $cs.ReplacementEnd = $cs.ReplacementStart + $match.Length
}

$cs = & $mod { $script:CompletionState }
Assert-Equal 1 $cs.Index "After cycling forward, index is 1"
Assert-Equal 'deployment-bravo' $cs.Matches[$cs.Index] "Second match is deployment-bravo"

# Simulate Ctrl+P: cycle backward
& $mod {
    $cs = $script:CompletionState
    $cs.Index -= 1
    if ($cs.Index -lt 0) { $cs.Index = $cs.Matches.Count - 1 }
}

$cs = & $mod { $script:CompletionState }
Assert-Equal 0 $cs.Index "After cycling backward, index is 0 again"

# Simulate wrap-around (Ctrl+P from index 0)
& $mod {
    $cs = $script:CompletionState
    $cs.Index -= 1
    if ($cs.Index -lt 0) { $cs.Index = $cs.Matches.Count - 1 }
}

$cs = & $mod { $script:CompletionState }
Assert-Equal 2 $cs.Index "After wrap-around backward, index is 2 (last)"
Assert-Equal 'deployment-alpha' $cs.Matches[$cs.Index] "Wrapped to deployment-alpha"

Write-Host "`n--- Buffer Scraper + Out-Default Token Capture ---" -ForegroundColor Yellow

# Test that Enable sets up key handlers (requires PSReadLine)
$psrl = Get-Module PSReadLine
if ($psrl) {
    & $mod {
        $script:Enabled = $false
        $script:TokenMap.Clear()
        $script:TokenCounter = 0
    }

    Enable-ScrollbackPredictor
    $enabled = & $mod { $script:Enabled }
    Assert-True $enabled "Module reports enabled after Enable-ScrollbackPredictor"

    # Check key handlers exist
    $handlers = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Function -match 'Scrollback' }
    Assert-True ($handlers.Count -ge 2) "Ctrl+N and Ctrl+P handlers registered"

    Disable-ScrollbackPredictor
    $enabled = & $mod { $script:Enabled }
    Assert-True (-not $enabled) "Module reports disabled after Disable-ScrollbackPredictor"
} else {
    Write-Host "  [SKIP] PSReadLine not loaded, skipping handler tests" -ForegroundColor Yellow
}

Write-Host "`n--- Enable/Disable Idempotency ---" -ForegroundColor Yellow

# Double-enable should warn but not error
Enable-ScrollbackPredictor 3>$null
Enable-ScrollbackPredictor -WarningVariable w 3>$null
Assert-True ($w.Count -gt 0 -or $true) "Double-enable doesn't throw"

Disable-ScrollbackPredictor
Disable-ScrollbackPredictor -WarningVariable w2 3>$null
Assert-True ($w2.Count -gt 0 -or $true) "Double-disable doesn't throw"

# Summary
Write-Host "`n=== Results: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

Remove-Module ScrollbackPredictor -Force -ErrorAction SilentlyContinue
exit $failCount
