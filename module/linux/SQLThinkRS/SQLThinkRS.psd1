@{
    RootModule        = 'SQLThinkRS.psm1'
    ModuleVersion     = '0.1.9'
    GUID              = 'b4f8d9e2-3c5e-5a7b-af1d-2e3f4a5b6c7d'
    Author            = 'HealisticEngineer'
    Description       = 'PowerShell module for SQLThinkRS - a Rust-based SQL Server client library (Linux)'
    PowerShellVersion = '7.0'
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
