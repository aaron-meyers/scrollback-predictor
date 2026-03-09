# ScrollbackPredictor

Vim-style **Ctrl+N / Ctrl+P** token completion for PowerShell, powered by PSReadLine.

Captures tokens from previous command output and offers them as completions while you type — just like `Ctrl+N` in vim's insert mode.

## How It Works

### Output Interception (two complementary mechanisms)

| Mechanism | What it captures | How |
|-----------|-----------------|-----|
| **Console buffer scraping** | Everything visible: Write-Host, native commands, errors | Reads `$Host.UI.RawUI.GetBufferContents()` via a `prompt` function hook after each command |
| **Out-Default proxy** | Structured pipeline output (objects, formatted tables) | Global `Out-Default` override with steppable pipeline pass-through |

Both run simultaneously — the buffer scraper catches everything the user sees, while the Out-Default proxy captures structured data that may not yet be rendered.

### Token Completion

PSReadLine key handlers intercept **Ctrl+N** (next match) and **Ctrl+P** (previous match). The completion engine:

1. Extracts the word prefix at the cursor
2. Searches the token store for case-insensitive prefix matches
3. Returns matches sorted by recency (most recently seen first)
4. Cycles through matches on repeated presses
5. After the last match, cycles back to the original typed prefix (vim behavior)
6. Does not override Escape — compatible with PSReadLine vi mode

Tokens are extracted by splitting on whitespace and decomposing paths/dotted names into components (e.g., `C:\Users\foo\bar.txt` yields `bar.txt`, `bar`, `foo`, `Users`, etc.).

## Installation

```powershell
Import-Module .\ScrollbackPredictor\ScrollbackPredictor.psd1
Enable-ScrollbackPredictor
```

Add to your `$PROFILE` for persistent use:

```powershell
Import-Module "C:\path\to\ScrollbackPredictor\ScrollbackPredictor.psd1"
Enable-ScrollbackPredictor
```

## Usage

| Key | Action |
|-----|--------|
| **Ctrl+N** | Complete / cycle forward through matches (wraps to original text) |
| **Ctrl+P** | Cycle backward through matches (wraps to original text) |

### Diagnostic Commands

```powershell
Get-ScrollbackTokenCount          # Number of tokens in the store
Get-ScrollbackToken -Prefix "dep" # Find tokens starting with "dep"
Get-ScrollbackToken -Count 20     # Show 20 most recent tokens
Disable-ScrollbackPredictor       # Turn off (removes hooks and key handlers)
```

## Requirements

- **PowerShell 5.1+** or **PowerShell 7+**
- **PSReadLine** module (ships with PowerShell by default)
- Windows (console buffer scraping uses Windows Console APIs)

## Running Tests

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-TokenStore.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-CompletionHandler.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-BufferScraper.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests\Test-OutDefaultProxy.ps1
```

## Design Notes

Two approaches for output interception were evaluated and both are used:

- **Console buffer scraping** is the primary mechanism. It reads the Win32 console screen buffer via `$Host.UI.RawUI.GetBufferContents()`, triggered from a `prompt` function hook. This captures everything visible to the user regardless of how it was produced. If the host doesn't support buffer reading, it disables itself silently.

- **Out-Default proxy** complements buffer scraping by intercepting structured pipeline output. It overrides the global `Out-Default` function with a steppable pipeline wrapper that extracts tokens from formatted output. This doesn't capture `Write-Host` or direct native command output, but provides a reliable fallback for non-console hosts.

The token store is a `Dictionary<string, long>` mapping tokens to a monotonic counter for recency ordering, with automatic eviction when capacity is exceeded.
