# SQLThinkRS

A high-performance Rust DLL for SQL Server access from PowerShell, with **built-in snapshot isolation** that eliminates read blocking under write locks.

## Features

- **Native Rust DLL** — called from PowerShell via P/Invoke (no managed dependencies)
- **Built-in Snapshot Isolation** — SELECT queries never block on locked rows; reads return the last committed version instantly
- **Auto-injected Primary Keys** — CREATE TABLE statements automatically get an `ID INT PRIMARY KEY IDENTITY(1,1)` column
- **DECLARE & CTE Support** — `DECLARE ... SELECT` and `WITH ... SELECT` (Common Table Expressions) are fully supported and return JSON results
- **JSON Result Sets** — SELECT results are returned as JSON arrays for easy consumption in PowerShell
- **Connection Pooling** — `DisconnectDb` returns connections to an internal pool; subsequent `ConnectDb` calls with the same connection string reuse them instantly (like ADO.NET pooling)
- **Explicit Transaction API** — `BeginTransaction`/`CommitTransaction` exports for batching writes (eliminates per-row auto-commit log flushes)
- **Trace Logging** — optional `EnableTrace()`/`DisableTrace()` for debugging SQL execution

## Quick Start

### Build

```bat
.\build.bat
```

Requires [Rust](https://rustup.rs/) with the `stable-x86_64-pc-windows-msvc` toolchain.

### Test

```powershell
powershell -ExecutionPolicy Bypass -File test.ps1
```

### Usage from PowerShell

```powershell
# Load the DLL via P/Invoke
$DllPath = ".\target\release\sqlthinkrs.dll"
$DllFullPath = (Resolve-Path $DllPath).Path

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class SqlThinkRS {
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

# Connect
$connStr = "server=localhost;user id=sa;password=YourPassword;database=YourDb;trust server certificate=true"
$err = [SqlThinkRS]::ConnectDb($connStr)

# Execute a SELECT — returns JSON
$ptr = [SqlThinkRS]::ExecuteSql("SELECT * FROM MyTable")
$json = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr)
[SqlThinkRS]::FreeCString($ptr)
$rows = $json | ConvertFrom-Json

# Execute a non-SELECT — returns null on success
[SqlThinkRS]::ExecuteSql("INSERT INTO MyTable (Name) VALUES ('Alice')")

# Disconnect
[SqlThinkRS]::DisconnectDb()
```

## API

| Export | Signature | Description |
|---|---|---|
| `ConnectDb` | `(string connStr) -> IntPtr` | Connect to SQL Server (checks pool first). Returns null on success, error string on failure. |
| `DisconnectDb` | `() -> void` | Return the connection to the pool for reuse. |
| `ExecuteSql` | `(string sql) -> IntPtr` | Execute SQL. Returns JSON for SELECT, null for non-SELECT, error string on failure. |
| `FreeCString` | `(IntPtr ptr) -> void` | Free a string returned by `ConnectDb` or `ExecuteSql`. |
| `BeginTransaction` | `() -> IntPtr` | Start an explicit transaction. Returns null on success. |
| `CommitTransaction` | `() -> IntPtr` | Commit the active transaction. Returns null on success. |
| `EnableTrace` | `() -> void` | Turn on SQL trace output to stderr. |
| `DisableTrace` | `() -> void` | Turn off SQL trace output. |

## Performance Benchmarks

Compared against the **SqlServer PowerShell module** (`Invoke-Sqlcmd`) and **.NET SqlClient** (`System.Data.SqlClient`) on localhost.

### Results Summary (150 iterations, 50 000 rows)

```
Provider         Operation                Iterations  Total (ms)  Avg (ms)
--------         ---------                ----------  ----------  --------
SqlServer Module Connect+Query(SELECT 1)         150    1,530.66    10.20
.NET SqlClient   Connect+Query(SELECT 1)         150      971.84     6.48
SQLThinkRS       Connect+Query(SELECT 1)         150      247.69     1.65
SqlServer Module SELECT (5 rows)                 150      140.40     0.94
.NET SqlClient   SELECT (5 rows)                 150      150.96     1.01
SQLThinkRS       SELECT (5 rows)                 150      120.84     0.81
SqlServer Module INSERT (50000 rows)           50000   45,385.01     0.91
.NET SqlClient   INSERT (50000 rows)           50000   42,381.02     0.85
SQLThinkRS       INSERT (50000 rows)           50000   39,888.13     0.80
SqlServer Module SELECT (50000 rows)             150    4,047.05    26.98
.NET SqlClient   SELECT (50000 rows)             150    4,007.74    26.72
SQLThinkRS       SELECT (50000 rows)             150    4,293.59    28.62
SqlServer Module SELECT under lock                 1    3,028.27  3028.27
.NET SqlClient   SELECT under lock                 1    3,007.43  3007.43
SQLThinkRS       SELECT under lock                 1        4.63     4.63
```

### Comparative Ranking

```
Connect+Query(SELECT 1)
  SQLThinkRS                1.65 ms avg  (1x)      ** WINNER **
  .NET SqlClient            6.48 ms avg  (3.92x)
  SqlServer Module         10.20 ms avg  (6.18x)

SELECT (5 rows)
  SQLThinkRS                0.81 ms avg  (1x)      ** WINNER **
  SqlServer Module          0.94 ms avg  (1.16x)
  .NET SqlClient            1.01 ms avg  (1.25x)

INSERT (50000 rows)
  SQLThinkRS                0.80 ms avg  (1x)      ** WINNER **
  .NET SqlClient            0.85 ms avg  (1.06x)
  SqlServer Module          0.91 ms avg  (1.14x)

SELECT (50000 rows)
  .NET SqlClient           26.72 ms avg  (1x)
  SqlServer Module         26.98 ms avg  (1.01x)
  SQLThinkRS               28.62 ms avg  (1.07x)

SELECT under lock
  SQLThinkRS                4.63 ms avg  (1x)      ** WINNER **
  .NET SqlClient        3,007.43 ms avg  (650x)    BLOCKED
  SqlServer Module      3,028.27 ms avg  (655x)    BLOCKED
```

### Key Takeaways

- **Connection speed**: SQLThinkRS with built-in connection pooling is the fastest at **1.65 ms** — **3.9x faster** than .NET SqlClient (6.48 ms) and **6.2x faster** than the SqlServer module (10.20 ms).
- **Small SELECTs**: By sending `BEGIN TRANSACTION; SELECT; COMMIT` as a single TDS batch (one round-trip instead of three), SQLThinkRS leads at **0.81 ms** — **25% faster** than .NET SqlClient.
- **Bulk INSERTs**: With explicit transaction wrapping and `simple_query` (no `sp_executesql` overhead), SQLThinkRS leads at **0.80 ms/row** — **6% faster** than .NET SqlClient.
- **Large result sets**: At 50 000 rows .NET SqlClient leads at 26.72 ms vs 28.62 ms (**1.07x**) — the gap is small since payload size dominates protocol overhead.
- **Snapshot Isolation (the killer feature)**: When another connection holds an exclusive write lock, both the SqlServer module and .NET SqlClient **block for 3+ seconds** (until timeout). SQLThinkRS reads the same rows in **4.63 ms** — over **650x faster** — because snapshot isolation is built in and always active.

### How Snapshot Isolation Works

SQLThinkRS sets `TRANSACTION ISOLATION LEVEL SNAPSHOT` at connection time and wraps every SELECT in an explicit transaction (as a single batch). This means reads always see the last committed version of the data, even when other connections hold exclusive locks. No configuration needed — it just works.

## Project Structure

```
SQLThinkRS/
  Cargo.toml        # Rust project config (cdylib output)
  build.bat         # Clean build script with DLL lock handling
  test.ps1          # Functional test (10-step: connect/CRUD/DECLARE/CTE/disconnect)
  perf_test.ps1     # Performance benchmark suite
  src/
    lib.rs          # Core Rust DLL implementation
```

## Dependencies

| Crate | Version | Purpose |
|---|---|---|
| `tiberius` | 0.12 | SQL Server TDS protocol client |
| `tokio` | 1 | Async runtime |
| `serde_json` | 1 | JSON serialization of result sets |
| `once_cell` | 1.20 | Global singleton (runtime, connection) |
| `regex` | 1 | CREATE TABLE parsing for PK injection |

## License

MIT
