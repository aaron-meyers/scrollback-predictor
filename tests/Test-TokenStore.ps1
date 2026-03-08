<#
.SYNOPSIS
    Tests for the token store, extraction, and completion logic.
.DESCRIPTION
    Imports the module and exercises the internal functions to verify correctness
    of token extraction, storage, prefix matching, and recency ordering.
#>

param(
    [switch]$InPwsh
)

# Re-launch in pwsh if requested
if ($InPwsh -and $PSVersionTable.PSVersion.Major -lt 7) {
    pwsh -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
    return
}

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

Write-Host "=== ScrollbackPredictor Module Tests ===" -ForegroundColor Cyan
Write-Host "PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Gray

# Import the module
$modulePath = Join-Path $PSScriptRoot '..\ScrollbackPredictor\ScrollbackPredictor.psd1'
Import-Module $modulePath -Force

$mod = Get-Module ScrollbackPredictor

Write-Host "`n--- Token Extraction ---" -ForegroundColor Yellow

# Test basic text extraction
& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "hello world foo_bar baz123"
}

$count = Get-ScrollbackTokenCount
Assert-True ($count -ge 3) "Basic extraction: got $count tokens (expected >= 3)"

# Test that short tokens are filtered
& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "a b cd efg"
}
$count = Get-ScrollbackTokenCount
Assert-Equal 2 $count "Short token filter: only 'cd' and 'efg' should pass (min length 2)"

# Test path decomposition
& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "C:\Users\testuser\Documents\report.txt"
}
$tokens = Get-ScrollbackToken -Count 100
$tokenNames = if ($tokens -is [array]) {
    $tokens | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Token } }
} else {
    @($tokens) | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Token } }
}
Assert-True ($tokenNames -contains 'testuser') "Path decomposition: 'testuser' extracted"
Assert-True ($tokenNames -contains 'Documents') "Path decomposition: 'Documents' extracted"
Assert-True ($tokenNames -contains 'report') "Path decomposition: 'report' extracted"

# Test numeric-only tokens are filtered
& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "12345 abc123 67890"
}
$count = Get-ScrollbackTokenCount
Assert-Equal 1 $count "Numeric filter: only 'abc123' has letters"

Write-Host "`n--- Prefix Matching ---" -ForegroundColor Yellow

& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "foobar football foolish bazaar barista"
}

$matches = Get-ScrollbackToken -Prefix "foo"
Assert-Equal 3 $matches.Count "Prefix 'foo' matches 3 tokens"
Assert-True ($matches -contains 'foobar') "Prefix 'foo' includes 'foobar'"
Assert-True ($matches -contains 'football') "Prefix 'foo' includes 'football'"
Assert-True ($matches -contains 'foolish') "Prefix 'foo' includes 'foolish'"

$matches = Get-ScrollbackToken -Prefix "bar"
Assert-Equal 1 $matches.Count "Prefix 'bar' matches 1 token (barista, not bazaar)"
Assert-True ($matches -contains 'barista') "Prefix 'bar' includes 'barista'"

$matches = Get-ScrollbackToken -Prefix "xyz"
Assert-Equal 0 $matches.Count "Prefix 'xyz' matches 0 tokens"

Write-Host "`n--- Recency Ordering ---" -ForegroundColor Yellow

& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    # Add tokens in this order: alpha, bravo, charlie
    Extract-TokensFromText "appAlpha"
    Extract-TokensFromText "appBravo"
    Extract-TokensFromText "appCharlie"
}

$matches = Get-ScrollbackToken -Prefix "app"
Assert-Equal 'appCharlie' $matches[0] "Most recent token 'appCharlie' is first"
Assert-Equal 'appBravo' $matches[1] "Second most recent 'appBravo' is second"
Assert-Equal 'appAlpha' $matches[2] "Oldest token 'appAlpha' is last"

# Test that re-using a token updates its recency
& $mod {
    Extract-TokensFromText "appAlpha"  # Re-add alpha, making it most recent
}
$matches = Get-ScrollbackToken -Prefix "app"
Assert-Equal 'appAlpha' $matches[0] "After re-add, 'appAlpha' is now first"

Write-Host "`n--- Case Insensitive Matching ---" -ForegroundColor Yellow

& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    Extract-TokensFromText "MyVariable MYVARIABLE myVariable"
}

$count = Get-ScrollbackTokenCount
Assert-Equal 1 $count "Case-insensitive store: only 1 unique token"

$matches = Get-ScrollbackToken -Prefix "my"
Assert-Equal 1 $matches.Count "Case-insensitive prefix match works"

Write-Host "`n--- Capacity Eviction ---" -ForegroundColor Yellow

& $mod {
    $script:TokenMap.Clear()
    $script:TokenCounter = 0
    $script:Config.MaxTokens = 50  # Small limit for testing

    # Add 70 tokens
    for ($i = 0; $i -lt 70; $i++) {
        Add-Token "testToken$([char](65 + ($i % 26)))$i"
    }

    # Reset config
    $script:Config.MaxTokens = 10000
}

$count = Get-ScrollbackTokenCount
Assert-True ($count -le 60) "Eviction works: token count ($count) is within bounds"
Assert-True ($count -ge 50) "Eviction preserved at least 50 tokens"

# The most recent tokens should still be present
$matches = Get-ScrollbackToken -Prefix "testToken"
Assert-True ($matches.Count -gt 0) "Recent tokens survived eviction"

Write-Host "`n--- Module Functions ---" -ForegroundColor Yellow

# Test exported functions exist
Assert-True ($null -ne (Get-Command Enable-ScrollbackPredictor -ErrorAction SilentlyContinue)) "Enable-ScrollbackPredictor exists"
Assert-True ($null -ne (Get-Command Disable-ScrollbackPredictor -ErrorAction SilentlyContinue)) "Disable-ScrollbackPredictor exists"
Assert-True ($null -ne (Get-Command Get-ScrollbackToken -ErrorAction SilentlyContinue)) "Get-ScrollbackToken exists"
Assert-True ($null -ne (Get-Command Get-ScrollbackTokenCount -ErrorAction SilentlyContinue)) "Get-ScrollbackTokenCount exists"

# Summary
Write-Host "`n=== Results: $passCount passed, $failCount failed ===" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

Remove-Module ScrollbackPredictor -Force -ErrorAction SilentlyContinue

exit $failCount
