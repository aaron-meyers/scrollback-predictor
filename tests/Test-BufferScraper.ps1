<#
.SYNOPSIS
    Test console buffer scraping as an output interception mechanism.
.DESCRIPTION
    Tests whether $Host.UI.RawUI.GetBufferContents() can read text from the
    console buffer. This is the primary approach for capturing command output.
#>

Write-Host "=== Console Buffer Scraper Test ===" -ForegroundColor Cyan

# First, output some known text that we'll try to read back
$testTokens = @("AlphaToken_7492", "BravoPath_C:\fake\dir\file.txt", "CharlieVersion_3.14.159")
Write-Host "Writing test tokens to console:"
foreach ($t in $testTokens) {
    Write-Host "  $t"
}

# Now try to read the buffer
try {
    $rawUI = $Host.UI.RawUI
    $bufferSize = $rawUI.BufferSize
    $cursorPos = $rawUI.CursorPosition

    Write-Host "`nBuffer info: Width=$($bufferSize.Width), Height=$($bufferSize.Height), CursorY=$($cursorPos.Y)"

    # Read the last 30 lines (should contain our test output)
    $linesToRead = 30
    $top = [Math]::Max(0, $cursorPos.Y - $linesToRead)
    $rect = [System.Management.Automation.Host.Rectangle]::new(
        0,
        $top,
        $bufferSize.Width - 1,
        $cursorPos.Y
    )

    $buffer = $rawUI.GetBufferContents($rect)
    $rows = $rect.Bottom - $rect.Top + 1
    $cols = $rect.Right - $rect.Left + 1

    # Extract text line by line
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($row = 0; $row -lt $rows; $row++) {
        $sb = [System.Text.StringBuilder]::new($cols)
        for ($col = 0; $col -lt $cols; $col++) {
            [void]$sb.Append($buffer.GetValue($row, $col).Character)
        }
        $lines.Add($sb.ToString().TrimEnd())
    }

    $text = $lines -join "`n"

    # Verify we can find our test tokens
    Write-Host "`n--- Verification ---" -ForegroundColor Yellow
    $allFound = $true
    foreach ($t in $testTokens) {
        $found = $text.Contains($t)
        $status = if ($found) { "PASS" } else { "FAIL"; $allFound = $false }
        $color = if ($found) { "Green" } else { "Red" }
        Write-Host "  [$status] Token '$t' found in buffer: $found" -ForegroundColor $color
    }

    # Show token extraction
    Write-Host "`n--- Token Extraction Sample ---" -ForegroundColor Yellow
    $extractedTokens = $text -split '\s+' |
        ForEach-Object { $_ -replace '^[^\w]+|[^\w]+$', '' } |
        Where-Object { $_.Length -ge 2 -and $_ -match '[a-zA-Z]' } |
        Select-Object -Unique |
        Select-Object -Last 20
    foreach ($et in $extractedTokens) {
        Write-Host "  '$et'"
    }

    Write-Host "`n=== Buffer Scraping: $(if ($allFound) { 'SUCCESS' } else { 'PARTIAL/FAILED' }) ===" -ForegroundColor $(if ($allFound) { 'Green' } else { 'Red' })

} catch {
    Write-Host "`nERROR: GetBufferContents failed: $_" -ForegroundColor Red
    Write-Host "This host may not support buffer scraping." -ForegroundColor Yellow
    Write-Host "Exception type: $($_.Exception.GetType().FullName)" -ForegroundColor Yellow
}
