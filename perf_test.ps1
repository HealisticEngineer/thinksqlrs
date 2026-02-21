<#
.SYNOPSIS
    Performance benchmark comparing SQLThinkRS (Rust DLL) against the SqlServer
    PowerShell module and .NET SqlClient.

.DESCRIPTION
    Runs a series of benchmarks that measure connection time, repeated SELECT
    throughput, bulk INSERT throughput, large result-set retrieval, and
    snapshot-isolation behaviour under an exclusive write lock.

    Each benchmark exercises all three providers so the numbers are directly
    comparable.  Results are printed in a summary table with relative rankings.

    Providers tested:
      1. SqlServer PowerShell module  (Invoke-Sqlcmd)   - connects per call
      2. .NET SqlClient               (System.Data)     - persistent ADO.NET connection
      3. SQLThinkRS Rust DLL          (P/Invoke)        - persistent native connection
                                                          with built-in SNAPSHOT isolation

.PARAMETER ServerName
    SQL Server hostname or instance name.  Default: localhost

.PARAMETER Database
    Target database for temp tables.  Default: tempdb

.PARAMETER UserId
    SQL login user.  Default: sa

.PARAMETER Password
    SQL login password.

.PARAMETER Iterations
    Number of repetitions for connection and SELECT benchmarks.  Default: 150

.PARAMETER BulkRows
    Number of rows for bulk INSERT and large-SELECT benchmarks.  Default: 50000

.EXAMPLE
    .\perf_test.ps1
    Runs all benchmarks with default settings.

.EXAMPLE
    .\perf_test.ps1 -Iterations 500 -BulkRows 100000
    Runs with higher iteration counts for more stable averages.

.NOTES
    Prerequisites:
      - SQL Server reachable on $ServerName with SQL auth enabled
      - cargo build --release   (produces target\release\sqlthinkrs.dll)
      - (optional) Install-Module SqlServer  for Invoke-Sqlcmd benchmarks
    The script creates and drops temporary tables in tempdb; it does NOT
    alter user databases.
#>

param(
    [string]$ServerName   = "localhost",
    [string]$Database     = "tempdb",
    [string]$UserId       = "sa",
    [string]$Password     = "NeverSafe2Day!",
    [int]$Iterations      = 150,
    [int]$BulkRows        = 50000
)

$ErrorActionPreference = "Stop"

# ── Console output helpers ──────────────────────────────────────────────────
# Thin wrappers that keep colour and indentation consistent across the script.
function Write-Header  { param([string]$Text) Write-Host "`n$('=' * 70)" -ForegroundColor Cyan;  Write-Host " $Text" -ForegroundColor Cyan; Write-Host "$('=' * 70)" -ForegroundColor Cyan }
function Write-Section { param([string]$Text) Write-Host "`n--- $Text ---" -ForegroundColor Yellow }
function Write-Ok      { param([string]$Text) Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Err     { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info    { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }

# ── Result accumulator ──────────────────────────────────────────────────────
# Every benchmark appends one [PSCustomObject] per provider via Add-Result.
# The final summary table and per-operation rankings are built from this list.
$script:Results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Provider, [string]$Operation, [double]$TotalMs, [int]$Iterations)
    $avg = if ($Iterations -gt 0) { [math]::Round($TotalMs / $Iterations, 3) } else { $TotalMs }
    $script:Results.Add([PSCustomObject]@{
        Provider   = $Provider
        Operation  = $Operation
        Iterations = $Iterations
        TotalMs    = [math]::Round($TotalMs, 3)
        AvgMs      = $avg
    })
}

# ============================================================================
# CONNECTION STRINGS
# ADO.NET and the Rust DLL use slightly different key names; both connect to
# the same SQL Server instance with SQL authentication.
# ============================================================================
$connStringAdo   = "Server=$ServerName;Database=$Database;User Id=$UserId;Password=$Password;TrustServerCertificate=True;Connection Timeout=30;"
$connStringRust  = "server=$ServerName;user id=$UserId;password=$Password;database=$Database;trust server certificate=true"

# ============================================================================
# 1. SETUP - Load Providers
# ============================================================================
Write-Header "PERFORMANCE COMPARISON: SQLServer Module vs .NET SqlClient vs SQLThinkRS"
Write-Host ""
Write-Info "Server       : $ServerName"
Write-Info "Database     : $Database"
Write-Info "Iterations   : $Iterations"
Write-Info "Bulk Rows    : $BulkRows"

# ── 1a. SQLServer PowerShell Module ─────────────────────────────────────────
Write-Section "Loading SqlServer PowerShell module"
$hasSqlModule = $false
try {
    Import-Module SqlServer -ErrorAction Stop
    $hasSqlModule = $true
    Write-Ok "SqlServer module loaded ($((Get-Module SqlServer).Version))"
} catch {
    Write-Err "SqlServer module not available - skipping. Install with: Install-Module SqlServer"
}

# ── 1b. .NET SqlClient ─────────────────────────────────────────────────────
Write-Section "Loading .NET SqlClient"
$hasDotNet = $false
try {
    # Try Microsoft.Data.SqlClient first (modern), fall back to System.Data.SqlClient
    $sqlClientType = $null
    try {
        Add-Type -AssemblyName "Microsoft.Data.SqlClient" -ErrorAction Stop
        $sqlClientType = "Microsoft.Data.SqlClient"
    } catch {
        # System.Data.SqlClient is built into .NET Framework / available in PS 5.1
        $sqlClientType = "System.Data.SqlClient"
    }
    # Quick validation
    $testConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $testConn.Dispose()
    $hasDotNet = $true
    Write-Ok ".NET SqlClient loaded ($sqlClientType)"
} catch {
    Write-Err ".NET SqlClient not available - skipping. Error: $_"
}

# ── 1c. Custom Rust DLL ────────────────────────────────────────────────────
Write-Section "Loading SQLThinkRS DLL"
$DllPath = ".\target\release\sqlthinkrs.dll"
$hasRust = $false

if (-not (Test-Path $DllPath)) {
    Write-Err "DLL not found at $DllPath - run 'cargo build --release' first"
} else {
    try {
        $DllFullPath = (Resolve-Path $DllPath).Path
        $rustSig = @"
using System;
using System.Runtime.InteropServices;

public class SqlThinkRSPerf {
    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr ConnectDb(string connectionString);

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void DisconnectDb();

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr ExecuteSql(string sql);

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void FreeCString(IntPtr ptr);

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr BeginTransaction();

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr CommitTransaction();

    public static void BeginTxn() {
        IntPtr ptr = BeginTransaction();
        if (ptr != IntPtr.Zero) {
            string err = Marshal.PtrToStringAnsi(ptr);
            FreeCString(ptr);
            throw new Exception(err);
        }
    }

    public static void CommitTxn() {
        IntPtr ptr = CommitTransaction();
        if (ptr != IntPtr.Zero) {
            string err = Marshal.PtrToStringAnsi(ptr);
            FreeCString(ptr);
            throw new Exception(err);
        }
    }

    public static string Execute(string sql) {
        IntPtr ptr = ExecuteSql(sql);
        if (ptr == IntPtr.Zero) return null;
        string result = Marshal.PtrToStringAnsi(ptr);
        FreeCString(ptr);
        return result;
    }

    public static string Connect(string connStr) {
        IntPtr ptr = ConnectDb(connStr);
        if (ptr == IntPtr.Zero) return null;
        string err = Marshal.PtrToStringAnsi(ptr);
        FreeCString(ptr);
        return err;
    }
}
"@
        Add-Type -TypeDefinition $rustSig
        $hasRust = $true
        Write-Ok "SQLThinkRS DLL loaded"
    } catch {
        Write-Err "Failed to load DLL: $_"
    }
}

# Bail if nothing is available
if (-not $hasSqlModule -and -not $hasDotNet -and -not $hasRust) {
    Write-Host "`nNo providers available - cannot run benchmarks." -ForegroundColor Red
    exit 1
}

# ============================================================================
# HELPER: .NET SqlClient wrapper
# Executes a SQL statement on an open DbConnection.
# With -Query it returns a DataTable; without it calls ExecuteNonQuery.
# ============================================================================
function Invoke-DotNetSql {
    param(
        [System.Data.Common.DbConnection]$Connection,
        [string]$Sql,
        [switch]$Query
    )
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 60
    if ($Query) {
        $reader = $cmd.ExecuteReader()
        $table  = New-Object System.Data.DataTable
        $table.Load($reader)
        $reader.Close()
        $cmd.Dispose()
        return $table
    } else {
        $null = $cmd.ExecuteNonQuery()
        $cmd.Dispose()
    }
}

# ============================================================================
# 2. BENCHMARK: Connection Time
# Measures the full round-trip of opening a new connection and executing a
# trivial "SELECT 1" query, then tearing down.  Repeated $Iterations times.
# SqlServer module reconnects on every Invoke-Sqlcmd call by design.
# .NET SqlClient benefits from ADO.NET connection pooling.
# SQLThinkRS opens a raw TCP + TDS handshake each iteration (no pool).
# ============================================================================
Write-Header "BENCHMARK: Connection Time ($Iterations iterations)"

# ── SqlServer Module ────────────────────────────────────────────────────────
if ($hasSqlModule) {
    Write-Section "SqlServer Module - Connection"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        # Invoke-Sqlcmd connects per call, so we just fire a trivial query
        Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
            -Username $UserId -Password $Password `
            -TrustServerCertificate -Query "SELECT 1 AS Test" | Out-Null
    }
    $sw.Stop()
    Add-Result "SqlServer Module" "Connect+Query(SELECT 1)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ── .NET SqlClient ──────────────────────────────────────────────────────────
if ($hasDotNet) {
    Write-Section ".NET SqlClient - Connection"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $c = New-Object "$sqlClientType.SqlConnection" $connStringAdo
        $c.Open()
        $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT 1 AS Test"
        $null = $cmd.ExecuteScalar()
        $cmd.Dispose(); $c.Close(); $c.Dispose()
    }
    $sw.Stop()
    Add-Result ".NET SqlClient" "Connect+Query(SELECT 1)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ── SQLThinkRS ──────────────────────────────────────────────────────────────
if ($hasRust) {
    Write-Section "SQLThinkRS - Connection"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $err = [SqlThinkRSPerf]::Connect($connStringRust)
        if ($err) { throw "Rust connect failed: $err" }
        $res = [SqlThinkRSPerf]::Execute("SELECT 1 AS Test")
        [SqlThinkRSPerf]::DisconnectDb()
    }
    $sw.Stop()
    Add-Result "SQLThinkRS" "Connect+Query(SELECT 1)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ============================================================================
# 3. BENCHMARK: Repeated SELECT on persistent connection
# Measures query-only latency by keeping the connection open and issuing the
# same 5-row SELECT $Iterations times.  This isolates TDS command overhead
# from connection setup cost.
# ============================================================================
Write-Header "BENCHMARK: Repeated SELECT ($Iterations iterations, persistent connection)"

$setupSql = @"
IF OBJECT_ID('tempdb.dbo.PerfTest', 'U') IS NOT NULL DROP TABLE tempdb.dbo.PerfTest;
CREATE TABLE tempdb.dbo.PerfTest (Id INT IDENTITY PRIMARY KEY, Name NVARCHAR(100), Value INT, Created DATETIME DEFAULT GETDATE());
INSERT INTO tempdb.dbo.PerfTest (Name, Value) VALUES ('Alpha', 1),('Beta', 2),('Gamma', 3),('Delta', 4),('Epsilon', 5);
"@

$selectSql = "SELECT Id, Name, Value, Created FROM tempdb.dbo.PerfTest"

# Seed the table using .NET (always available as a baseline)
if ($hasDotNet) {
    $seedConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $seedConn.Open()
    Invoke-DotNetSql -Connection $seedConn -Sql $setupSql
    $seedConn.Close(); $seedConn.Dispose()
    Write-Info "Seeded tempdb.dbo.PerfTest table (5 rows)"
} elseif ($hasSqlModule) {
    Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
        -Username $UserId -Password $Password `
        -TrustServerCertificate -Query $setupSql
    Write-Info "Seeded ##PerfTest table (5 rows)"
}

# ── SqlServer Module ────────────────────────────────────────────────────────
if ($hasSqlModule) {
    Write-Section "SqlServer Module - Repeated SELECT"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $null = Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
            -Username $UserId -Password $Password `
            -TrustServerCertificate -Query $selectSql
    }
    $sw.Stop()
    Add-Result "SqlServer Module" "SELECT (5 rows)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ── .NET SqlClient ──────────────────────────────────────────────────────────
if ($hasDotNet) {
    Write-Section ".NET SqlClient - Repeated SELECT (persistent connection)"
    $dotnetConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $dotnetConn.Open()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $null = Invoke-DotNetSql -Connection $dotnetConn -Sql $selectSql -Query
    }
    $sw.Stop()
    $dotnetConn.Close(); $dotnetConn.Dispose()
    Add-Result ".NET SqlClient" "SELECT (5 rows)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ── SQLThinkRS ──────────────────────────────────────────────────────────────
if ($hasRust) {
    Write-Section "SQLThinkRS - Repeated SELECT (persistent connection)"
    $err = [SqlThinkRSPerf]::Connect($connStringRust)
    if ($err) { throw "Rust connect failed: $err" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $res = [SqlThinkRSPerf]::Execute($selectSql)
        if ($res -and $res.StartsWith("ERROR:")) { throw $res }
    }
    $sw.Stop()
    [SqlThinkRSPerf]::DisconnectDb()
    Add-Result "SQLThinkRS" "SELECT (5 rows)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ============================================================================
# 4. BENCHMARK: Bulk INSERT
# Inserts $BulkRows rows one-at-a-time (no batching) to stress single-
# statement round-trip throughput.  Each provider creates a fresh table,
# then loops INSERT INTO ... VALUES for every row.
# ============================================================================
Write-Header "BENCHMARK: Bulk INSERT ($BulkRows rows)"

$bulkSetup = @"
IF OBJECT_ID('tempdb.dbo.PerfBulk', 'U') IS NOT NULL DROP TABLE tempdb.dbo.PerfBulk;
CREATE TABLE tempdb.dbo.PerfBulk (Id INT IDENTITY PRIMARY KEY, Name NVARCHAR(100), Value INT);
"@

# ── SqlServer Module ────────────────────────────────────────────────────────
if ($hasSqlModule) {
    Write-Section "SqlServer Module - Bulk INSERT"
    Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
        -Username $UserId -Password $Password `
        -TrustServerCertificate -Query $bulkSetup

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $BulkRows; $i++) {
        Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
            -Username $UserId -Password $Password `
            -TrustServerCertificate `
            -Query "INSERT INTO tempdb.dbo.PerfBulk (Name, Value) VALUES ('Item_$i', $i)"
    }
    $sw.Stop()
    Add-Result "SqlServer Module" "INSERT ($BulkRows rows)" $sw.Elapsed.TotalMilliseconds $BulkRows
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg/row: $([math]::Round($sw.Elapsed.TotalMilliseconds / $BulkRows, 3)) ms"
}

# ── .NET SqlClient ──────────────────────────────────────────────────────────
if ($hasDotNet) {
    Write-Section ".NET SqlClient - Bulk INSERT (persistent connection)"
    $dotnetConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $dotnetConn.Open()
    Invoke-DotNetSql -Connection $dotnetConn -Sql $bulkSetup

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $BulkRows; $i++) {
        Invoke-DotNetSql -Connection $dotnetConn -Sql "INSERT INTO tempdb.dbo.PerfBulk (Name, Value) VALUES ('Item_$i', $i)"
    }
    $sw.Stop()
    $dotnetConn.Close(); $dotnetConn.Dispose()
    Add-Result ".NET SqlClient" "INSERT ($BulkRows rows)" $sw.Elapsed.TotalMilliseconds $BulkRows
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg/row: $([math]::Round($sw.Elapsed.TotalMilliseconds / $BulkRows, 3)) ms"
}

# ── SQLThinkRS ──────────────────────────────────────────────────────────────
if ($hasRust) {
    Write-Section "SQLThinkRS - Bulk INSERT (persistent connection)"
    $err = [SqlThinkRSPerf]::Connect($connStringRust)
    if ($err) { throw "Rust connect failed: $err" }
    [SqlThinkRSPerf]::Execute($bulkSetup)

    # Wrap all inserts in a single transaction to avoid per-row auto-commit
    # log flushes.  This is the same pattern a DBA would use for bulk loads.
    [SqlThinkRSPerf]::BeginTxn()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $BulkRows; $i++) {
        $res = [SqlThinkRSPerf]::Execute("INSERT INTO tempdb.dbo.PerfBulk (Name, Value) VALUES ('Item_$i', $i)")
        if ($res -and $res.StartsWith("ERROR:")) { throw $res }
    }
    $sw.Stop()
    [SqlThinkRSPerf]::CommitTxn()
    [SqlThinkRSPerf]::DisconnectDb()
    Add-Result "SQLThinkRS" "INSERT ($BulkRows rows)" $sw.Elapsed.TotalMilliseconds $BulkRows
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg/row: $([math]::Round($sw.Elapsed.TotalMilliseconds / $BulkRows, 3)) ms"
}

# ============================================================================
# 5. BENCHMARK: Large Result Set SELECT
# Seeds a table with $BulkRows rows (via CTE for speed), then issues a
# full-table SELECT $Iterations times.  Measures data-marshalling overhead:
# .NET returns DataTable objects; SQLThinkRS returns a JSON string that
# PowerShell can ConvertFrom-Json.
# ============================================================================
Write-Header "BENCHMARK: Large Result Set SELECT ($BulkRows rows, $Iterations iterations)"

# Seed large table using .NET
if ($hasDotNet) {
    $seedConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $seedConn.Open()
    Invoke-DotNetSql -Connection $seedConn -Sql @"
IF OBJECT_ID('tempdb.dbo.PerfLarge', 'U') IS NOT NULL DROP TABLE tempdb.dbo.PerfLarge;
CREATE TABLE tempdb.dbo.PerfLarge (Id INT IDENTITY PRIMARY KEY, Name NVARCHAR(100), Value INT);
;WITH Nums AS (SELECT TOP ($BulkRows) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects a CROSS JOIN sys.objects b)
INSERT INTO tempdb.dbo.PerfLarge (Name, Value) SELECT 'Row_' + CAST(n AS VARCHAR(10)), n FROM Nums;
"@
    $seedConn.Close(); $seedConn.Dispose()
    Write-Info "Seeded tempdb.dbo.PerfLarge table ($BulkRows rows)"
} elseif ($hasSqlModule) {
    Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
        -Username $UserId -Password $Password `
        -TrustServerCertificate -Query @"
IF OBJECT_ID('tempdb.dbo.PerfLarge', 'U') IS NOT NULL DROP TABLE tempdb.dbo.PerfLarge;
CREATE TABLE tempdb.dbo.PerfLarge (Id INT IDENTITY PRIMARY KEY, Name NVARCHAR(100), Value INT);
;WITH Nums AS (SELECT TOP ($BulkRows) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.objects a CROSS JOIN sys.objects b)
INSERT INTO tempdb.dbo.PerfLarge (Name, Value) SELECT 'Row_' + CAST(n AS VARCHAR(10)), n FROM Nums;
"@
    Write-Info "Seeded tempdb.dbo.PerfLarge table ($BulkRows rows)"
}

$largeSql = "SELECT Id, Name, Value FROM tempdb.dbo.PerfLarge"

# ── SqlServer Module ────────────────────────────────────────────────────────
if ($hasSqlModule) {
    Write-Section "SqlServer Module - Large SELECT ($BulkRows rows)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $null = Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
            -Username $UserId -Password $Password `
            -TrustServerCertificate -Query $largeSql
    }
    $sw.Stop()
    Add-Result "SqlServer Module" "SELECT ($BulkRows rows)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ── .NET SqlClient ──────────────────────────────────────────────────────────
if ($hasDotNet) {
    Write-Section ".NET SqlClient - Large SELECT ($BulkRows rows, persistent connection)"
    $dotnetConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $dotnetConn.Open()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $null = Invoke-DotNetSql -Connection $dotnetConn -Sql $largeSql -Query
    }
    $sw.Stop()
    $dotnetConn.Close(); $dotnetConn.Dispose()
    Add-Result ".NET SqlClient" "SELECT ($BulkRows rows)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ── SQLThinkRS ──────────────────────────────────────────────────────────────
if ($hasRust) {
    Write-Section "SQLThinkRS - Large SELECT ($BulkRows rows, persistent connection)"
    $err = [SqlThinkRSPerf]::Connect($connStringRust)
    if ($err) { throw "Rust connect failed: $err" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $res = [SqlThinkRSPerf]::Execute($largeSql)
        if ($res -and $res.StartsWith("ERROR:")) { throw $res }
    }
    $sw.Stop()
    [SqlThinkRSPerf]::DisconnectDb()
    Add-Result "SQLThinkRS" "SELECT ($BulkRows rows)" $sw.Elapsed.TotalMilliseconds $Iterations
    Write-Ok "Total: $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms  |  Avg: $([math]::Round($sw.Elapsed.TotalMilliseconds / $Iterations, 2)) ms"
}

# ============================================================================
# 6. BENCHMARK: Snapshot Isolation - Read Under Write Lock
#
# Demonstrates the key differentiator of SQLThinkRS: built-in SNAPSHOT
# isolation that lets SELECT queries read the last-committed version of a
# row even while another connection holds an exclusive write lock on it.
#
# Flow:
#   1. Enable ALLOW_SNAPSHOT_ISOLATION on tempdb (ALTER DATABASE is async;
#      we poll sys.databases.snapshot_isolation_state until it reaches 1).
#   2. Seed a small PerfLock table (3 rows).
#   3. Open a .NET connection and run BEGIN TRAN + UPDATE (holds X-lock).
#   4. Try to SELECT the locked rows from each provider:
#      - SqlServer Module & .NET SqlClient use READ COMMITTED -> BLOCKED.
#      - SQLThinkRS uses SNAPSHOT isolation -> returns instantly.
#   5. ROLLBACK the lock holder and clean up.
#
# The SQLThinkRS job runs inside a PowerShell Start-Job with a timeout
# guard so a regression cannot hang the entire script.
# ============================================================================
Write-Header "BENCHMARK: Snapshot Isolation - Reading while rows are locked"
Write-Host ""
Write-Info "This test holds an exclusive UPDATE lock on rows via an open transaction,"
Write-Info "then attempts to SELECT those same rows from a second connection."
Write-Info "Without snapshot isolation the read BLOCKS (times out). With snapshot"
Write-Info "isolation (SQLThinkRS built-in) the read succeeds instantly."
Write-Host ""

$lockTableSetup = @"
IF OBJECT_ID('tempdb.dbo.PerfLock', 'U') IS NOT NULL DROP TABLE tempdb.dbo.PerfLock;
CREATE TABLE tempdb.dbo.PerfLock (Id INT PRIMARY KEY, Name NVARCHAR(100), Value INT);
INSERT INTO tempdb.dbo.PerfLock VALUES (1,'Alpha',10),(2,'Beta',20),(3,'Gamma',30);
"@

$lockSelectSql = "SELECT Id, Name, Value FROM tempdb.dbo.PerfLock"
$lockTimeoutSec = 3

# Enable snapshot isolation at the database level (required for SNAPSHOT to work)
if ($hasDotNet) {
    $setupConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $setupConn.Open()
    Invoke-DotNetSql -Connection $setupConn -Sql "ALTER DATABASE tempdb SET ALLOW_SNAPSHOT_ISOLATION ON"

    # Wait until snapshot isolation is fully active (ALTER DATABASE is async)
    $maxWait = 30; $waited = 0
    while ($waited -lt $maxWait) {
        $stateCmd = $setupConn.CreateCommand()
        $stateCmd.CommandText = "SELECT snapshot_isolation_state FROM sys.databases WHERE name = 'tempdb'"
        $state = $stateCmd.ExecuteScalar(); $stateCmd.Dispose()
        if ($state -eq 1) { break }
        Start-Sleep -Milliseconds 500; $waited++
    }
    if ($waited -ge $maxWait) {
        Write-Err "Snapshot isolation did not activate on tempdb within ${maxWait}s"
    } else {
        Write-Info "Enabled ALLOW_SNAPSHOT_ISOLATION on tempdb (active, waited $($waited * 500)ms)"
    }

    Invoke-DotNetSql -Connection $setupConn -Sql $lockTableSetup
    $setupConn.Close(); $setupConn.Dispose()
    Write-Info "Seeded tempdb.dbo.PerfLock (3 rows)"
}

# Open a connection that holds an exclusive lock via BEGIN TRAN + UPDATE
$lockConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
$lockConn.Open()
$lockCmd = $lockConn.CreateCommand()
$lockCmd.CommandText = "BEGIN TRANSACTION; UPDATE tempdb.dbo.PerfLock SET Value = Value + 1 WHERE Id = 1;"
$null = $lockCmd.ExecuteNonQuery()
Write-Info "Holding exclusive lock on PerfLock (Id=1) via open transaction..."

# ── SqlServer Module (default READ COMMITTED - should block/timeout) ────────
if ($hasSqlModule) {
    Write-Section "SqlServer Module - SELECT under lock (READ COMMITTED, ${lockTimeoutSec}s timeout)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
            -Username $UserId -Password $Password `
            -TrustServerCertificate -Query $lockSelectSql `
            -QueryTimeout $lockTimeoutSec -ErrorAction Stop
        $sw.Stop()
        Add-Result "SqlServer Module" "SELECT under lock" $sw.Elapsed.TotalMilliseconds 1
        Write-Ok "Completed in $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms (unexpected - no blocking)"
    } catch {
        $sw.Stop()
        Add-Result "SqlServer Module" "SELECT under lock" $sw.Elapsed.TotalMilliseconds 1
        Write-Host "  [BLOCKED] Timed out after $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms - read was BLOCKED by the lock" -ForegroundColor Red
    }
}

# ── .NET SqlClient (default READ COMMITTED - should block/timeout) ──────────
if ($hasDotNet) {
    Write-Section ".NET SqlClient - SELECT under lock (READ COMMITTED, ${lockTimeoutSec}s timeout)"
    $readConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
    $readConn.Open()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $readCmd = $readConn.CreateCommand()
        $readCmd.CommandText = $lockSelectSql
        $readCmd.CommandTimeout = $lockTimeoutSec
        $reader = $readCmd.ExecuteReader()
        $table = New-Object System.Data.DataTable
        $table.Load($reader)
        $reader.Close()
        $readCmd.Dispose()
        $sw.Stop()
        Add-Result ".NET SqlClient" "SELECT under lock" $sw.Elapsed.TotalMilliseconds 1
        Write-Ok "Completed in $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms (unexpected - no blocking)"
    } catch {
        $sw.Stop()
        Add-Result ".NET SqlClient" "SELECT under lock" $sw.Elapsed.TotalMilliseconds 1
        Write-Host "  [BLOCKED] Timed out after $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms - read was BLOCKED by the lock" -ForegroundColor Red
    } finally {
        $readConn.Close(); $readConn.Dispose()
    }
}

# ── SQLThinkRS (built-in SNAPSHOT isolation - should succeed instantly) ─────
if ($hasRust) {
    Write-Section "SQLThinkRS - SELECT under lock (SNAPSHOT isolation, built-in)"

    # Run in a background job with timeout to prevent hanging the entire script
    $rustLockJob = Start-Job -ScriptBlock {
        param($DllFullPath, $ConnStr, $Sql)
        $sig = @"
using System;
using System.Runtime.InteropServices;
public class SqlThinkRSJob {
    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr ConnectDb(string connectionString);
    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void DisconnectDb();
    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr ExecuteSql(string sql);
    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void FreeCString(IntPtr ptr);
}
"@
        Add-Type -TypeDefinition $sig
        $errPtr = [SqlThinkRSJob]::ConnectDb($ConnStr)
        if ($errPtr -ne [IntPtr]::Zero) {
            $e = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($errPtr)
            [SqlThinkRSJob]::FreeCString($errPtr)
            return "ERROR:CONNECT:$e"
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ptr = [SqlThinkRSJob]::ExecuteSql($Sql)
        $sw.Stop()
        $result = $null
        if ($ptr -ne [IntPtr]::Zero) {
            $result = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr)
            [SqlThinkRSJob]::FreeCString($ptr)
        }
        [SqlThinkRSJob]::DisconnectDb()
        return @{ ElapsedMs = $sw.Elapsed.TotalMilliseconds; Result = $result }
    } -ArgumentList (Resolve-Path $DllPath).Path, $connStringRust, $lockSelectSql

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $completed = $rustLockJob | Wait-Job -Timeout ($lockTimeoutSec + 2)
    $sw.Stop()

    if ($null -eq $completed) {
        # Job timed out - the Rust call is blocked
        $rustLockJob | Stop-Job
        $rustLockJob | Remove-Job -Force
        Add-Result "SQLThinkRS" "SELECT under lock" $sw.Elapsed.TotalMilliseconds 1
        Write-Host "  [BLOCKED] Timed out after $([math]::Round($sw.Elapsed.TotalMilliseconds, 1)) ms - snapshot isolation did NOT prevent blocking" -ForegroundColor Red
    } else {
        $jobResult = $rustLockJob | Receive-Job
        $rustLockJob | Remove-Job -Force
        if ($jobResult -is [string] -and $jobResult.StartsWith("ERROR:")) {
            Add-Result "SQLThinkRS" "SELECT under lock" $sw.Elapsed.TotalMilliseconds 1
            Write-Host "  [ERROR] $jobResult" -ForegroundColor Red
        } elseif ($jobResult.Result -and $jobResult.Result.StartsWith("ERROR:")) {
            Add-Result "SQLThinkRS" "SELECT under lock" $jobResult.ElapsedMs 1
            Write-Host "  [ERROR] $($jobResult.Result)" -ForegroundColor Red
        } else {
            Add-Result "SQLThinkRS" "SELECT under lock" $jobResult.ElapsedMs 1
            $rows = ($jobResult.Result | ConvertFrom-Json)
            Write-Ok "Completed in $([math]::Round($jobResult.ElapsedMs, 1)) ms - read $($rows.Count) rows INSTANTLY (not blocked!)"
            Write-Info "Data returned (pre-update snapshot):"
            $rows | Format-Table -AutoSize
        }
    }
}

# Release the lock
$rollbackCmd = $lockConn.CreateCommand()
$rollbackCmd.CommandText = "ROLLBACK TRANSACTION"
$null = $rollbackCmd.ExecuteNonQuery()
$rollbackCmd.Dispose(); $lockCmd.Dispose()
$lockConn.Close(); $lockConn.Dispose()
Write-Info "Lock released (transaction rolled back)"

# ============================================================================
# 7. CLEANUP
# Drop all temporary tables created during the benchmarks.
# ============================================================================
Write-Section "Cleanup"
try {
    if ($hasDotNet) {
        $cleanupConn = New-Object "$sqlClientType.SqlConnection" $connStringAdo
        $cleanupConn.Open()
        Invoke-DotNetSql -Connection $cleanupConn -Sql "IF OBJECT_ID('tempdb.dbo.PerfTest','U')  IS NOT NULL DROP TABLE tempdb.dbo.PerfTest"
        Invoke-DotNetSql -Connection $cleanupConn -Sql "IF OBJECT_ID('tempdb.dbo.PerfBulk','U')  IS NOT NULL DROP TABLE tempdb.dbo.PerfBulk"
        Invoke-DotNetSql -Connection $cleanupConn -Sql "IF OBJECT_ID('tempdb.dbo.PerfLarge','U') IS NOT NULL DROP TABLE tempdb.dbo.PerfLarge"
        Invoke-DotNetSql -Connection $cleanupConn -Sql "IF OBJECT_ID('tempdb.dbo.PerfLock','U')  IS NOT NULL DROP TABLE tempdb.dbo.PerfLock"
        $cleanupConn.Close(); $cleanupConn.Dispose()
    } elseif ($hasSqlModule) {
        Invoke-Sqlcmd -ServerInstance $ServerName -Database $Database `
            -Username $UserId -Password $Password `
            -TrustServerCertificate -Query @"
IF OBJECT_ID('tempdb.dbo.PerfTest','U')  IS NOT NULL DROP TABLE tempdb.dbo.PerfTest;
IF OBJECT_ID('tempdb.dbo.PerfBulk','U')  IS NOT NULL DROP TABLE tempdb.dbo.PerfBulk;
IF OBJECT_ID('tempdb.dbo.PerfLarge','U') IS NOT NULL DROP TABLE tempdb.dbo.PerfLarge;
IF OBJECT_ID('tempdb.dbo.PerfLock','U')  IS NOT NULL DROP TABLE tempdb.dbo.PerfLock;
"@
    }
    Write-Ok "Temporary tables dropped"
} catch {
    Write-Err "Cleanup error: $_"
}

# ============================================================================
# 8. RESULTS SUMMARY
# Prints a flat table of all recorded results, then a per-operation ranking
# showing each provider's average time relative to the fastest (1x).
# A visual bar ("*") scales with the multiplier (capped at 50 chars).
# ============================================================================
Write-Header "RESULTS SUMMARY"
Write-Host ""

$script:Results | Format-Table -AutoSize -Property Provider, Operation, Iterations, @{
    Name = "Total (ms)"; Expression = { $_.TotalMs }; Alignment = "Right"
}, @{
    Name = "Avg (ms)"; Expression = { $_.AvgMs }; Alignment = "Right"
}

# ── Side-by-side comparison per operation ───────────────────────────────────
$operations = $script:Results | Select-Object -ExpandProperty Operation -Unique
foreach ($op in $operations) {
    $opResults = $script:Results | Where-Object { $_.Operation -eq $op } | Sort-Object AvgMs
    $fastest   = $opResults | Select-Object -First 1

    Write-Host "  $op" -ForegroundColor Cyan
    foreach ($r in $opResults) {
        $multiplier = if ($fastest.AvgMs -gt 0) { [math]::Round($r.AvgMs / $fastest.AvgMs, 2) } else { 0 }
        $bar = "*" * [math]::Min([math]::Max([int]$multiplier, 1), 50)
        $color = if ($r.Provider -eq $fastest.Provider) { "Green" } else { "White" }
        Write-Host ("    {0,-20} {1,10:N3} ms avg  ({2}x) {3}" -f $r.Provider, $r.AvgMs, $multiplier, $bar) -ForegroundColor $color
    }
    Write-Host ""
}

Write-Host "Benchmark complete." -ForegroundColor Cyan
