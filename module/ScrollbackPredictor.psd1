@{
    RootModule        = 'ScrollbackPredictor.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'f3b3e7a0-6c1a-4e2d-9f5b-8a7c3d2e1f00'
    Author            = 'Aaron'
    Description       = 'PSReadLine predictor that suggests completions from previous command output.'
    PowerShellVersion = '7.4'
    RequiredAssemblies = @('ScrollbackPredictor.dll')
    FunctionsToExport = @('Clear-ScrollbackIndex', 'Get-ScrollbackIndexCount')
    CmdletsToExport   = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('PSReadLine', 'Predictor', 'Completion', 'Scrollback')
            ProjectUri = 'https://github.com/aaron/scrollback-predictor'
        }
    }
}
