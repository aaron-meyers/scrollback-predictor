using namespace System.Management.Automation
using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

# Register the predictor subsystem
$predictor = [ScrollbackPredictor.ScrollbackPredictor]::new()
[SubsystemManager]::RegisterSubsystem([SubsystemKind]::CommandPredictor, $predictor)

# Proxy Out-Default to intercept pipeline output
$wrappedCmd = Get-Command Microsoft.PowerShell.Core\Out-Default
$cmdMeta = [System.Management.Automation.CommandMetaData]::new($wrappedCmd)
$proxyBody = [System.Management.Automation.ProxyCommand]::Create($cmdMeta)
$proxyScriptBlock = [ScriptBlock]::Create($proxyBody)

function Global:Out-Default {
    [CmdletBinding()]
    param(
        [switch]$Transcript,
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject
    )

    begin {
        $steppablePipeline = $script:proxyScriptBlock.GetSteppablePipeline($MyInvocation.CommandOrigin)
        $steppablePipeline.Begin($PSCmdlet)
    }

    process {
        if ($null -ne $InputObject) {
            try {
                $text = $InputObject.ToString()
                [ScrollbackPredictor.ScrollbackIndex]::AddLine($text)
            } catch {
                # Silently ignore indexing errors
            }
        }
        $steppablePipeline.Process($InputObject)
    }

    end {
        $steppablePipeline.End()
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
    } catch {
        # Ignore if already unregistered
    }

    # Remove the Out-Default proxy
    Remove-Item Function:\Out-Default -ErrorAction SilentlyContinue
}
