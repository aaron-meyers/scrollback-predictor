<#
.SYNOPSIS
    Vim-style Ctrl+N/Ctrl+P token completion from previous command output.

.DESCRIPTION
    ScrollbackPredictor captures tokens from command output using two mechanisms:
    1. Console buffer scraping (captures everything visible including Write-Host, native commands)
    2. Out-Default proxy (captures structured pipeline output)

    Tokens are indexed and made available via Ctrl+N (next match) and Ctrl+P (previous match)
    keybindings in PSReadLine, similar to vim's insert-mode completion.

.NOTES
    Requires PSReadLine module (included with PowerShell 5.1+ and PowerShell 7+).
#>

#region ---- Configuration ----

$script:Config = @{
    MaxTokens          = 10000     # Maximum unique tokens to store
    MinTokenLength     = 2         # Minimum token length to index
    MaxTokenLength     = 500       # Maximum token length to index
    BufferLinesToRead  = 500       # Max console buffer lines to read per scrape
    MaxPendingObjects  = 5000      # Max objects to buffer in Out-Default proxy
    EnableBufferScrape = $true     # Use console buffer scraping
    EnableOutDefault   = $true     # Use Out-Default proxy
}

#endregion

#region ---- Token Store ----

# Stores tokens mapped to a monotonically increasing counter for recency ordering.
# Higher counter = more recently seen.
$script:TokenMap = [System.Collections.Generic.Dictionary[string, long]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$script:TokenCounter = [long]0
$script:Enabled = $false
$script:OriginalPrompt = $null

function script:Add-Token([string]$Token) {
    $Token = $Token.Trim()
    if ($Token.Length -lt $script:Config.MinTokenLength -or
        $Token.Length -gt $script:Config.MaxTokenLength -or
        $Token -notmatch '[a-zA-Z]') {
        return
    }
    $script:TokenCounter++
    $script:TokenMap[$Token] = $script:TokenCounter

    # Evict oldest tokens when over capacity
    if ($script:TokenMap.Count -gt ($script:Config.MaxTokens * 1.2)) {
        $evictCount = $script:TokenMap.Count - $script:Config.MaxTokens
        $oldest = $script:TokenMap.GetEnumerator() |
            Sort-Object Value |
            Select-Object -First $evictCount |
            ForEach-Object { $_.Key }
        foreach ($key in $oldest) {
            $script:TokenMap.Remove($key) | Out-Null
        }
    }
}

function script:Extract-TokensFromText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }

    # Split on whitespace, then clean leading/trailing non-word chars
    $rawTokens = $Text -split '[\s\r\n]+'
    foreach ($raw in $rawTokens) {
        if (-not $raw) { continue }

        # Strip leading/trailing punctuation but keep internal special chars (paths, URLs)
        $cleaned = $raw -replace '^[^\w/\\~\.]+' -replace '[^\w/\\~\.]+$'
        if ($cleaned) {
            Add-Token $cleaned
        }

        # Also index sub-components of paths and dotted names
        if ($cleaned -match '[/\\:]') {
            $parts = $cleaned -split '[/\\:]+'
            foreach ($part in $parts) {
                $part = $part -replace '^[^\w]+|[^\w]+$', ''
                if ($part) {
                    Add-Token $part
                    # Decompose dotted filenames within paths (e.g., report.txt → report, txt)
                    if ($part -match '\.') {
                        foreach ($dp in ($part -split '\.')) {
                            $dp = $dp -replace '^[^\w]+|[^\w]+$', ''
                            if ($dp) { Add-Token $dp }
                        }
                    }
                }
            }
        }
        if ($cleaned -match '\.' -and $cleaned -notmatch '[/\\:]') {
            $parts = $cleaned -split '\.'
            foreach ($part in $parts) {
                $part = $part -replace '^[^\w]+|[^\w]+$', ''
                if ($part) { Add-Token $part }
            }
        }
    }
}

function script:Find-TokenMatches([string]$Prefix) {
    if ([string]::IsNullOrWhiteSpace($Prefix)) { return @() }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($entry in $script:TokenMap.GetEnumerator()) {
        if ($entry.Key.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            $entry.Key -ne $Prefix) {
            $results.Add([PSCustomObject]@{ Token = $entry.Key; Recency = $entry.Value })
        }
    }
    # Sort by recency descending (most recently seen first)
    $sorted = $results | Sort-Object -Property Recency -Descending | ForEach-Object { $_.Token }
    return @($sorted)
}

#endregion

#region ---- Console Buffer Scraper ----

$script:LastCursorY = -1

function script:Read-ConsoleBuffer {
    try {
        $rawUI = $Host.UI.RawUI
        if ($null -eq $rawUI -or $null -eq $rawUI.BufferSize) { return }

        $bufferSize = $rawUI.BufferSize
        $cursorPos = $rawUI.CursorPosition
        $currentY = $cursorPos.Y

        if ($script:LastCursorY -lt 0) {
            # First run - read last N lines
            $top = [Math]::Max(0, $currentY - $script:Config.BufferLinesToRead)
        } else {
            # Read only lines since last scrape
            $top = [Math]::Max(0, $script:LastCursorY)
            if ($top -ge $currentY) {
                # No new output
                $script:LastCursorY = $currentY
                return
            }
        }

        $bottom = [Math]::Max($top, $currentY - 1)  # Don't read the current prompt line
        if ($bottom -lt $top) {
            $script:LastCursorY = $currentY
            return
        }

        # Limit read size
        $maxTop = [Math]::Max($top, $bottom - $script:Config.BufferLinesToRead)
        $top = $maxTop

        $rect = [System.Management.Automation.Host.Rectangle]::new(
            0, $top, $bufferSize.Width - 1, $bottom
        )
        $buffer = $rawUI.GetBufferContents($rect)
        $rows = $bottom - $top + 1
        $cols = $bufferSize.Width

        $sb = [System.Text.StringBuilder]::new($cols * $rows)
        for ($row = 0; $row -lt $rows; $row++) {
            $lineBuilder = [System.Text.StringBuilder]::new($cols)
            for ($col = 0; $col -lt $cols; $col++) {
                [void]$lineBuilder.Append($buffer.GetValue($row, $col).Character)
            }
            [void]$sb.AppendLine($lineBuilder.ToString().TrimEnd())
        }

        Extract-TokensFromText $sb.ToString()
        $script:LastCursorY = $currentY
    }
    catch {
        # Buffer scraping not supported in this host; disable silently
        $script:Config.EnableBufferScrape = $false
    }
}

#endregion

#region ---- Out-Default Proxy ----

function script:Install-OutDefaultProxy {
    # Store pending objects in a module-scoped variable so the global function can access it
    $script:OutDefaultPendingObjects = $null

    $modulePath = $MyInvocation.ScriptName
    $moduleScope = $script:MyInvocation.MyCommand.ScriptBlock.Module

    # Create the proxy function in global scope
    $proxyFunc = {
        [CmdletBinding()]
        param(
            [switch]${Transcript},
            [Parameter(ValueFromPipeline = $true)]
            [psobject]${InputObject}
        )

        begin {
            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand(
                'Microsoft.PowerShell.Core\Out-Default',
                [System.Management.Automation.CommandTypes]::Cmdlet
            )
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)

            $pending = [System.Collections.Generic.List[object]]::new()
            $ExecutionContext.SessionState.PSVariable.Set('__sbpPending', $pending)
        }

        process {
            if ($null -ne $InputObject) {
                $p = $ExecutionContext.SessionState.PSVariable.GetValue('__sbpPending')
                if ($null -ne $p -and $p.Count -lt 5000) {
                    $p.Add($InputObject)
                }
            }
            $steppablePipeline.Process($InputObject)
        }

        end {
            $p = $ExecutionContext.SessionState.PSVariable.GetValue('__sbpPending')
            if ($null -ne $p -and $p.Count -gt 0) {
                try {
                    $text = ($p | Out-String -Width 500).Trim()
                    & (Get-Module ScrollbackPredictor) { param($t) Extract-TokensFromText $t } $text
                } catch {}
            }
            $steppablePipeline.End()
        }
    }

    Set-Item -Path Function:\global:Out-Default -Value $proxyFunc
}

function script:Uninstall-OutDefaultProxy {
    Remove-Item Function:\global:Out-Default -ErrorAction SilentlyContinue
}

#endregion

#region ---- Prompt Hook ----

function script:Install-PromptHook {
    # Save the original prompt function
    $script:OriginalPrompt = Get-Item Function:\prompt -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ScriptBlock }

    if (-not $script:OriginalPrompt) {
        $script:OriginalPrompt = { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
    }

    # Route everything through the module scope so $script: variables resolve correctly
    Set-Item -Path Function:\global:prompt -Value {
        $mod = Get-Module ScrollbackPredictor
        if ($mod) {
            & $mod {
                if ($script:Config.EnableBufferScrape) {
                    Read-ConsoleBuffer
                }
                & $script:OriginalPrompt
            }
        } else {
            "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
        }
    }
}

function script:Uninstall-PromptHook {
    if ($script:OriginalPrompt) {
        Set-Item -Path Function:\global:prompt -Value $script:OriginalPrompt
    }
}

#endregion

#region ---- Completion Handler (Ctrl+N / Ctrl+P) ----

$script:CompletionState = @{
    Active           = $false
    OriginalPrefix   = ''     # What the user originally typed
    Matches          = @()    # List of matching tokens
    Index            = -1     # Current index in matches
    ReplacementStart = 0      # Where the word starts in the buffer
    ReplacementEnd   = 0      # Where the replacement ends (changes as we cycle)
}

function script:Get-WordBoundary {
    param([string]$Line, [int]$Cursor)

    $wordStart = $Cursor
    while ($wordStart -gt 0 -and $Line[$wordStart - 1] -match '[\w\-\.:/@\\~]') {
        $wordStart--
    }
    return $wordStart
}

function script:Invoke-TokenCompletion {
    param([int]$Direction)  # 1 = forward (Ctrl+N), -1 = backward (Ctrl+P)

    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    $cs = $script:CompletionState

    if ($cs.Active) {
        # Check if we're still in a valid completion cycle:
        # The buffer between ReplacementStart and ReplacementEnd should contain
        # the currently selected match
        if ($cs.ReplacementStart -ge $line.Length -or $cs.ReplacementEnd -gt $line.Length) {
            $cs.Active = $false
        } else {
            $currentMatch = $cs.Matches[$cs.Index]
            $replLen = $cs.ReplacementEnd - $cs.ReplacementStart
            $bufferWord = $line.Substring($cs.ReplacementStart, $replLen)

            if ($bufferWord -ne $currentMatch) {
                # User edited the buffer; reset completion state
                $cs.Active = $false
            }
        }
    }

    if (-not $cs.Active) {
        # Start new completion cycle

        # Scrape buffer for latest tokens before completing
        if ($script:Config.EnableBufferScrape) {
            try { Read-ConsoleBuffer } catch {}
        }

        $wordStart = Get-WordBoundary $line $cursor
        $prefix = $line.Substring($wordStart, $cursor - $wordStart)

        if ([string]::IsNullOrEmpty($prefix)) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Ding()
            return
        }

        $matches = Find-TokenMatches $prefix
        if ($matches.Count -eq 0) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Ding()
            return
        }

        $cs.Active = $true
        $cs.OriginalPrefix = $prefix
        $cs.Matches = $matches
        $cs.Index = if ($Direction -eq 1) { 0 } else { $matches.Count - 1 }
        $cs.ReplacementStart = $wordStart
        $cs.ReplacementEnd = $cursor
    } else {
        # Cycle to next/previous match
        $cs.Index += $Direction
        if ($cs.Index -ge $cs.Matches.Count) { $cs.Index = 0 }
        if ($cs.Index -lt 0) { $cs.Index = $cs.Matches.Count - 1 }
    }

    # Replace the word in the buffer
    $match = $cs.Matches[$cs.Index]
    $replLen = $cs.ReplacementEnd - $cs.ReplacementStart
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
        $cs.ReplacementStart,
        $replLen,
        $match
    )
    $cs.ReplacementEnd = $cs.ReplacementStart + $match.Length
}

function script:Install-KeyHandlers {
    Set-PSReadLineKeyHandler -Key Ctrl+n -BriefDescription 'ScrollbackCompleteNext' `
        -LongDescription 'Complete token from scrollback history (next match)' `
        -ScriptBlock {
            & (Get-Module ScrollbackPredictor) { Invoke-TokenCompletion -Direction 1 }
        }

    Set-PSReadLineKeyHandler -Key Ctrl+p -BriefDescription 'ScrollbackCompletePrev' `
        -LongDescription 'Complete token from scrollback history (previous match)' `
        -ScriptBlock {
            & (Get-Module ScrollbackPredictor) { Invoke-TokenCompletion -Direction (-1) }
        }

    # Reset completion state on Escape
    Set-PSReadLineKeyHandler -Key Escape -BriefDescription 'ScrollbackCompleteCancel' `
        -LongDescription 'Cancel scrollback completion and revert to original prefix' `
        -ScriptBlock {
            $cs = & (Get-Module ScrollbackPredictor) { $script:CompletionState }
            if ($cs.Active) {
                $replLen = $cs.ReplacementEnd - $cs.ReplacementStart
                [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
                    $cs.ReplacementStart,
                    $replLen,
                    $cs.OriginalPrefix
                )
                $cs.Active = $false
            } else {
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            }
        }
}

function script:Uninstall-KeyHandlers {
    Remove-PSReadLineKeyHandler -Key Ctrl+n -ErrorAction SilentlyContinue
    Remove-PSReadLineKeyHandler -Key Ctrl+p -ErrorAction SilentlyContinue
    Remove-PSReadLineKeyHandler -Key Escape -ErrorAction SilentlyContinue
}

#endregion

#region ---- Public Functions ----

function Enable-ScrollbackPredictor {
    <#
    .SYNOPSIS
        Enables scrollback token completion.
    .DESCRIPTION
        Installs the prompt hook, Out-Default proxy, and PSReadLine key handlers
        for Ctrl+N/Ctrl+P token completion.
    #>
    [CmdletBinding()]
    param()

    if ($script:Enabled) {
        Write-Warning "ScrollbackPredictor is already enabled."
        return
    }

    # Verify PSReadLine is available
    $psrl = Get-Module PSReadLine
    if (-not $psrl) {
        Write-Warning "PSReadLine module is not loaded. Key handlers will not be installed."
        return
    }

    if ($script:Config.EnableBufferScrape) {
        Install-PromptHook
    }
    if ($script:Config.EnableOutDefault) {
        Install-OutDefaultProxy
    }
    Install-KeyHandlers

    $script:Enabled = $true
    Write-Verbose "ScrollbackPredictor enabled. Use Ctrl+N/Ctrl+P to complete tokens from output."
}

function Disable-ScrollbackPredictor {
    <#
    .SYNOPSIS
        Disables scrollback token completion.
    .DESCRIPTION
        Removes the prompt hook, Out-Default proxy, and PSReadLine key handlers.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:Enabled) {
        Write-Warning "ScrollbackPredictor is not enabled."
        return
    }

    Uninstall-KeyHandlers
    Uninstall-PromptHook
    Uninstall-OutDefaultProxy

    $script:Enabled = $false
    Write-Verbose "ScrollbackPredictor disabled."
}

function Get-ScrollbackToken {
    <#
    .SYNOPSIS
        Shows tokens currently in the scrollback token store.
    .PARAMETER Prefix
        Optional filter to show only tokens starting with this prefix.
    .PARAMETER Count
        Maximum number of tokens to return (default: 50).
    #>
    [CmdletBinding()]
    param(
        [string]$Prefix,
        [int]$Count = 50
    )

    $results = if ($Prefix) {
        Find-TokenMatches $Prefix | Select-Object -First $Count
    } else {
        $script:TokenMap.GetEnumerator() |
            Sort-Object Value -Descending |
            Select-Object -First $Count |
            ForEach-Object {
                [PSCustomObject]@{
                    Token   = $_.Key
                    Recency = $_.Value
                }
            }
    }

    $results
}

function Get-ScrollbackTokenCount {
    <#
    .SYNOPSIS
        Returns the number of tokens currently stored.
    #>
    [CmdletBinding()]
    param()

    $script:TokenMap.Count
}

#endregion

#region ---- Module Lifecycle ----

# Auto-enable when imported in an interactive session
$isInteractive = [Environment]::UserInteractive -and
    -not [Environment]::GetCommandLineArgs().Where({ $_ -eq '-NonInteractive' -or $_ -eq '-File' })

if ($isInteractive -or $Host.Name -eq 'ConsoleHost') {
    # Delay enable slightly to let PSReadLine initialize
    $ExecutionContext.SessionState.Module.OnRemove = {
        Disable-ScrollbackPredictor
    }
}

Export-ModuleMember -Function @(
    'Enable-ScrollbackPredictor'
    'Disable-ScrollbackPredictor'
    'Get-ScrollbackToken'
    'Get-ScrollbackTokenCount'
)

#endregion
