# ScrollbackPredictor

PowerShell PSReadLine predictor that suggests completions from previous command output.

## What it does

When you run a command that produces output (e.g. `winget search copilot`), ScrollbackPredictor captures tokens from that output and offers them as inline predictions the next time you type. This means identifiers, package names, paths, and other useful strings that appeared in your terminal become completion candidates — even if no argument completer exists for the command you're typing.

## Requirements

- PowerShell 7.4+
- PSReadLine with `PredictionSource` set to include plugins

## Building

```powershell
dotnet build src -c Release
```

This outputs `ScrollbackPredictor.dll` into the `module/` directory.

## Installation

1. Build the project (see above).
2. Copy the `module/` folder to your PowerShell modules directory:

```powershell
Copy-Item -Recurse .\module\ "$HOME\Documents\PowerShell\Modules\ScrollbackPredictor"
```

3. Add to your `$PROFILE`:

```powershell
Import-Module ScrollbackPredictor
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
```

## Usage

Once loaded, the predictor works automatically:

```
> winget search copilot
GitHub.Copilot.Preview    ...
Microsoft.Copilot         ...

> winget install Git          # press F2 for list view, or see inline suggestions
  → GitHub.Copilot.Preview    # suggested from previous output
```

### Helper commands

| Command | Description |
|---------|-------------|
| `Clear-ScrollbackIndex` | Clear all captured tokens |
| `Get-ScrollbackIndexCount` | Show how many tokens are currently indexed |

## How it works

1. **Output capture** — The module wraps `Out-Default` with a proxy that feeds each output line to `ScrollbackIndex.AddLine()`.
2. **Token indexing** — Interesting tokens (identifiers, paths, package IDs — 3+ chars, not purely numeric) are stored in a concurrent dictionary with a rolling cap of 10,000 entries.
3. **Prediction** — When you type, the `ICommandPredictor` implementation extracts the last partial token and matches it against the index.

## License

See [LICENSE](LICENSE).
