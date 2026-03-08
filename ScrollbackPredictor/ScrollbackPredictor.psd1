@{
    RootModule        = 'ScrollbackPredictor.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a3f7b2c1-9d4e-4f8a-b6c5-1e2d3f4a5b6c'
    Author            = 'ScrollbackPredictor Contributors'
    Description       = 'Vim-style Ctrl+N/Ctrl+P token completion from previous command output in PowerShell.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('PSReadLine')

    FunctionsToExport = @(
        'Enable-ScrollbackPredictor'
        'Disable-ScrollbackPredictor'
        'Get-ScrollbackToken'
        'Get-ScrollbackTokenCount'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('PSReadLine', 'completion', 'vim', 'scrollback', 'token')
            LicenseUri = 'https://github.com/scrollback-predictor/blob/main/LICENSE'
            ProjectUri = 'https://github.com/scrollback-predictor'
        }
    }
}
