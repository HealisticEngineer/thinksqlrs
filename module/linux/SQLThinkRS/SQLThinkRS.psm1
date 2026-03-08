# SQLThinkRS PowerShell Module - Linux (.so)

$script:NativeLoaded = $false

function Initialize-NativeLibrary {
    if ($script:NativeLoaded) { return }

    $soPath = Join-Path $PSScriptRoot 'libsqlthinkrs.so'
    if (-not (Test-Path $soPath)) {
        throw "SQLThinkRS native library not found at '$soPath'. Copy libsqlthinkrs.so from target/release/ into the module folder."
    }
    $fullPath = (Resolve-Path $soPath).Path

    $signature = @"
using System;
using System.Runtime.InteropServices;

public class SqlThinkRSNative {
    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr ConnectDb(string connectionString);

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void DisconnectDb();

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr ExecuteSql(string sql);

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void FreeCString(IntPtr ptr);

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr BeginTransaction();

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr CommitTransaction();

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void EnableTrace();

    [DllImport("$fullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void DisableTrace();
}
"@
    Add-Type -TypeDefinition $signature
    $script:NativeLoaded = $true
}

function Read-NativeResult {
    param([IntPtr]$Ptr)
    if ($Ptr -eq [IntPtr]::Zero) { return $null }
    $str = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($Ptr)
    [SqlThinkRSNative]::FreeCString($Ptr)
    return $str
}

function Connect-SqlThinkRS {
    <#
    .SYNOPSIS
        Connects to a SQL Server database.
    .PARAMETER ConnectionString
        The connection string for the SQL Server database.
    .PARAMETER Server
        The server name or address.
    .PARAMETER Database
        The database name.
    .PARAMETER UserId
        The SQL login user id.
    .PARAMETER Password
        The password for the SQL login.
    .PARAMETER TrustServerCertificate
        Trust the server certificate (default: true).
    #>
    [CmdletBinding(DefaultParameterSetName = 'ConnectionString')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ConnectionString', Position = 0)]
        [string]$ConnectionString,

        [Parameter(Mandatory, ParameterSetName = 'Parts')]
        [string]$Server,

        [Parameter(Mandatory, ParameterSetName = 'Parts')]
        [string]$Database,

        [Parameter(Mandatory, ParameterSetName = 'Parts')]
        [string]$UserId,

        [Parameter(Mandatory, ParameterSetName = 'Parts')]
        [string]$Password,

        [Parameter(ParameterSetName = 'Parts')]
        [switch]$TrustServerCertificate = $true
    )

    Initialize-NativeLibrary

    if ($PSCmdlet.ParameterSetName -eq 'Parts') {
        $ConnectionString = "server=$Server;user id=$UserId;password=$Password;database=$Database"
        if ($TrustServerCertificate) {
            $ConnectionString += ";trust server certificate=true"
        }
    }

    $errorPtr = [SqlThinkRSNative]::ConnectDb($ConnectionString)
    $errorMsg = Read-NativeResult $errorPtr
    if ($errorMsg) {
        throw $errorMsg
    }
}

function Disconnect-SqlThinkRS {
    <#
    .SYNOPSIS
        Disconnects from the current SQL Server database connection.
    #>
    [CmdletBinding()]
    param()

    Initialize-NativeLibrary
    [SqlThinkRSNative]::DisconnectDb()
}

function Invoke-SqlThinkRS {
    <#
    .SYNOPSIS
        Executes a SQL statement against the connected SQL Server database.
    .PARAMETER Sql
        The SQL statement to execute.
    .PARAMETER AsJson
        Return the raw JSON string instead of parsed objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Sql,

        [switch]$AsJson
    )

    Initialize-NativeLibrary

    $resultPtr = [SqlThinkRSNative]::ExecuteSql($Sql)
    if ($resultPtr -eq [IntPtr]::Zero) {
        return $null
    }

    $result = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($resultPtr)
    [SqlThinkRSNative]::FreeCString($resultPtr)

    if ($result -and $result.StartsWith("ERROR:")) {
        throw $result
    }

    if ($AsJson) {
        return $result
    }

    if ($result) {
        return ($result | ConvertFrom-Json)
    }
}

function Start-SqlThinkRSTransaction {
    <#
    .SYNOPSIS
        Begins a new transaction on the current connection.
    #>
    [CmdletBinding()]
    param()

    Initialize-NativeLibrary

    $errorPtr = [SqlThinkRSNative]::BeginTransaction()
    $errorMsg = Read-NativeResult $errorPtr
    if ($errorMsg) {
        throw $errorMsg
    }
}

function Complete-SqlThinkRSTransaction {
    <#
    .SYNOPSIS
        Commits the current transaction.
    #>
    [CmdletBinding()]
    param()

    Initialize-NativeLibrary

    $errorPtr = [SqlThinkRSNative]::CommitTransaction()
    $errorMsg = Read-NativeResult $errorPtr
    if ($errorMsg) {
        throw $errorMsg
    }
}

function Enable-SqlThinkRSTrace {
    <#
    .SYNOPSIS
        Enables SQL trace output to stderr for debugging.
    #>
    [CmdletBinding()]
    param()

    Initialize-NativeLibrary
    [SqlThinkRSNative]::EnableTrace()
}

function Disable-SqlThinkRSTrace {
    <#
    .SYNOPSIS
        Disables SQL trace output.
    #>
    [CmdletBinding()]
    param()

    Initialize-NativeLibrary
    [SqlThinkRSNative]::DisableTrace()
}

Export-ModuleMember -Function @(
    'Connect-SqlThinkRS'
    'Disconnect-SqlThinkRS'
    'Invoke-SqlThinkRS'
    'Start-SqlThinkRSTransaction'
    'Complete-SqlThinkRSTransaction'
    'Enable-SqlThinkRSTrace'
    'Disable-SqlThinkRSTrace'
)
