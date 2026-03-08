<#
.SYNOPSIS
    Test Out-Default proxy function as an output interception mechanism.
.DESCRIPTION
    Overrides Out-Default with a proxy that captures pipeline output tokens.
    Tests that tokens are captured from various output types.
#>

Write-Host "=== Out-Default Proxy Test ===" -ForegroundColor Cyan

# Token storage (global so the proxy function can access it)
$global:_OutDefaultTestTokens = [System.Collections.Generic.List[string]]::new()

function global:_ExtractTokens([string]$text) {
    $text -split '\s+' |
        ForEach-Object { $_ -replace '^[^\w]+|[^\w]+$', '' } |
        Where-Object { $_.Length -ge 2 -and $_ -match '[a-zA-Z]' }
}

# Install proxy in global scope with fully-qualified reference to real cmdlet
function global:Out-Default {
    [CmdletBinding()]
    param(
        [switch]${Transcript},
        [Parameter(ValueFromPipeline = $true)]
        [psobject]${InputObject}
    )

    begin {
        $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Core\Out-Default', [System.Management.Automation.CommandTypes]::Cmdlet)
        $scriptCmd = { & $wrappedCmd @PSBoundParameters }
        $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
        $steppablePipeline.Begin($PSCmdlet)
        $global:_pendingObjects = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($null -ne $InputObject -and $global:_pendingObjects.Count -lt 2000) {
            $global:_pendingObjects.Add($InputObject)
        }
        $steppablePipeline.Process($InputObject)
    }

    end {
        if ($global:_pendingObjects.Count -gt 0) {
            try {
                $text = ($global:_pendingObjects | Out-String -Width 500).Trim()
                $tokens = _ExtractTokens $text
                foreach ($token in $tokens) {
                    $global:_OutDefaultTestTokens.Add($token)
                }
            } catch {
                # Silently ignore tokenization errors
            }
        }
        $steppablePipeline.End()
    }
}

Write-Host "Proxy installed. Running test commands..." -ForegroundColor Yellow

# Test 1: Simple string output - use explicit piping to force immediate processing
"UniqueTestString_8675309" | Out-Default

# Test 2: Object output
[PSCustomObject]@{ ServerName = "ProdServer_Alpha"; Port = 8443; Status = "Healthy_Running" } | Out-Default

# Test 3: Command output
Get-Process -Id $PID | Select-Object Name, Id, WorkingSet64 | Out-Default

Write-Host "`n--- Captured Tokens ---" -ForegroundColor Yellow
$unique = $global:_OutDefaultTestTokens | Select-Object -Unique
foreach ($t in $unique) {
    Write-Host "  '$t'"
}

# Verify specific tokens were captured
Write-Host "`n--- Verification ---" -ForegroundColor Yellow
$expectedTokens = @("UniqueTestString_8675309", "ProdServer_Alpha", "Healthy_Running")
$allFound = $true
foreach ($expected in $expectedTokens) {
    $found = $unique -contains $expected
    $status = if ($found) { "PASS" } else { "FAIL"; $allFound = $false }
    $color = if ($found) { "Green" } else { "Red" }
    Write-Host "  [$status] Token '$expected' captured: $found" -ForegroundColor $color
}

# Test what we DON'T capture
Write-Host "`n--- Limitations ---" -ForegroundColor Yellow
Write-Host "WriteHost_Token_NotCaptured_12345"
$whCaptured = $unique -contains "WriteHost_Token_NotCaptured_12345"
Write-Host "  [INFO] Write-Host token captured: $whCaptured (expected: False)" -ForegroundColor $(if (-not $whCaptured) { "Green" } else { "Yellow" })

Write-Host "`n=== Out-Default Proxy: $(if ($allFound) { 'SUCCESS' } else { 'PARTIAL/FAILED' }) ===" -ForegroundColor $(if ($allFound) { 'Green' } else { 'Red' })

# Cleanup
Remove-Item Function:\global:Out-Default -ErrorAction SilentlyContinue
Remove-Item Function:\global:_ExtractTokens -ErrorAction SilentlyContinue
Remove-Variable -Name _OutDefaultTestTokens -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name _pendingObjects -Scope Global -ErrorAction SilentlyContinue
