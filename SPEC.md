You’re describing something that PowerShell **does not do natively** and that no existing module really solves:  
a predictor that watches **arbitrary recent terminal output** and turns any word/identifier/path/package‑ID/etc. into a completion candidate.

But the good news is: **PowerShell’s predictor API *can* support this**, and you can build it yourself with surprisingly little code.

Let me lay out what’s possible and what the architecture looks like so you can decide how deep you want to go.

---

# 🧠 What you want: “output‑aware completion”
You want something like this:

1. Run a command  
   `winget search copilot`
2. Terminal prints a bunch of words  
   `GitHub.Copilot.Preview`, `Microsoft.Copilot`, etc.
3. Later, you type  
   `winget install Git<TAB>`
4. PowerShell suggests completions based on **those words from earlier output**, not history, not plugins.

This is basically a **scrollback‑aware predictor**.

PowerShell doesn’t ship one.  
No module currently does this.  
But the predictor API absolutely allows it.

---

# 🧩 How you would build it

## 1. Create a custom PSReadLine predictor
Predictors are just .NET classes implementing:

```csharp
using System.Management.Automation.Subsystem.Prediction;

public class ScrollbackPredictor : ICommandPredictor
{
    public Guid Id => Guid.Parse("YOUR-GUID-HERE");
    public string Name => "ScrollbackPredictor";

    public SuggestionPackage GetSuggestion(PredictionClient client, PredictionContext context, CancellationToken token)
    {
        var input = context.InputAst.Extent.Text;
        var suggestions = ScrollbackIndex.FindMatches(input);
        return new SuggestionPackage(suggestions);
    }
}
```

You register it with:

```powershell
Register-PSSubsystem -Subsystem Prediction -Name ScrollbackPredictor -TypeName ScrollbackPredictor
```

---

## 2. Maintain a rolling index of “interesting words”
You can hook into PowerShell’s output stream using:

- A proxy function wrapper  
- A transcript parser  
- Or a custom host that intercepts `WriteObject`

Simplest approach: wrap `Out-Default`:

```powershell
$global:ScrollbackWords = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

$ExecutionContext.InvokeCommand.PreCommandLookupAction = {
    Register-EngineEvent PowerShell.OnCommandOutput -Action {
        param($data)
        $data | ForEach-Object {
            $_.ToString() -split '\W+' | ForEach-Object {
                if ($_ -match '^[\w\.-]{3,}$') {
                    $global:ScrollbackWords.Add($_)
                }
            }
        }
    }
}
```

Now every time PowerShell prints something, you collect tokens like:

- `GitHub.Copilot.Preview`
- `Microsoft.PowerShell.Core`
- `my-file-name`
- `SomeIdentifier123`

---

## 3. The predictor uses that index
Your predictor’s `FindMatches` might look like:

```csharp
public static IEnumerable<PredictiveSuggestion> FindMatches(string input)
{
    return ScrollbackWords
        .Where(w => w.StartsWith(input, StringComparison.OrdinalIgnoreCase))
        .Distinct()
        .Take(20)
        .Select(w => new PredictiveSuggestion(w));
}
```

Now anything that appeared in recent output becomes a completion candidate.

---

# 🧪 What this gives you in practice
You get a shell that behaves like:

```
> winget search copilot
GitHub.Copilot.Preview
Microsoft.Copilot
...

> winget install Git<TAB>
```

…and it completes to `GitHub.Copilot.Preview` even though:

- winget doesn’t provide completions  
- no argument completer exists  
- you never typed it before  
- it only appeared in output  

This is exactly the “arbitrary output → completion” behavior you’re after.

---

# 🧭 If you want, I can sketch a minimal working prototype
I can put together:

- a tiny PowerShell module  
- a C# predictor class  
- a scrollback indexer  
- a registration script  

…so you can drop it into your `$PROFILE` and have this working with minimal fuss.

Just tell me whether you want:

- **PowerShell‑only version** (slower, easier)  
- **C# compiled predictor** (fast, clean, proper plugin)  

Either way, I can shape it into something ergonomic for your workflow.