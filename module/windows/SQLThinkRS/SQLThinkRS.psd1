@{
    RootModule        = 'SQLThinkRS.psm1'
    ModuleVersion     = '0.1.10'
    GUID              = 'a3f7c8e1-2b4d-4f6a-9e0c-1d2e3f4a5b6c'
    Author            = 'HealisticEngineer'
    Description       = 'PowerShell module for SQLThinkRS - a Rust-based SQL Server client library (Windows)'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Connect-SqlThinkRS'
        'Disconnect-SqlThinkRS'
        'Invoke-SqlThinkRS'
        'Start-SqlThinkRSTransaction'
        'Complete-SqlThinkRSTransaction'
        'Enable-SqlThinkRSTrace'
        'Disable-SqlThinkRSTrace'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
