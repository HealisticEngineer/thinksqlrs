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

### Benchmark Methodology

- Secure defaults are enabled in `perf_test.ps1`: `Encrypt=$true` and `TrustServerCertificate=$false`.
- Warmup iterations are run before timed loops (`-WarmupIterations`, default 10) to reduce cold-start noise.
- For local dev SQL Server instances with self-signed certificates, run with `-TrustServerCertificate:$true` explicitly.
- Snapshot isolation lock behavior is validated with an explicit blocked-reader test (`SELECT under lock`).

### Run The Benchmark

```powershell
.\perf_test.ps1 -Iterations 150 -BulkRows 50000 -WarmupIterations 10 -TrustServerCertificate:$true
```

Use `-TrustServerCertificate:$false` in environments with trusted server certificates.

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

- **Connection speed**: SQLThinkRS with optimized connection pooling (no ping validation) achieves **0.67 ms** — **1.41x faster** than .NET SqlClient (0.95 ms).
- **Small SELECTs**: By sending `BEGIN TRANSACTION; SELECT; COMMIT` as a single TDS batch (one round-trip instead of three), SQLThinkRS leads at **0.63 ms** — **1.83x faster** than .NET SqlClient.
- **Bulk INSERTs**: With explicit transaction wrapping and `simple_query` (no `sp_executesql` overhead), SQLThinkRS leads at **0.65 ms/row** — **1.28x faster** than .NET SqlClient.
- **Large result sets**: At 50,000 rows, SQLThinkRS achieves **26.12 ms** vs .NET's **24.06 ms** (**1.09x** behind) — type caching optimization reduced the gap significantly, with remaining difference attributed to native TDS implementation advantages.
- **Snapshot Isolation (the killer feature)**: When another connection holds an exclusive write lock, .NET SqlClient **blocks for 3+ seconds** (until timeout). SQLThinkRS reads the same rows in **3.31 ms** — over **900x faster** — because snapshot isolation is built in and always active.

### Latest Local Run (2026-06-09)

Environment notes:
- SqlServer PowerShell module was not installed on this host, so this run compares **.NET SqlClient vs SQLThinkRS**.
- Run command used secure transport with explicit local self-signed override: `-TrustServerCertificate:$true`.
- Includes v0.1.8 performance optimizations: connection pool ping removal, column type caching for large result sets.

```
Provider       Operation               Iterations Total (ms) Avg (ms)
--------       ---------               ---------- ---------- --------
.NET SqlClient Connect+Query(SELECT 1)        150     141.86     0.95
SQLThinkRS     Connect+Query(SELECT 1)        150     100.88     0.67
.NET SqlClient SELECT (5 rows)                150     173.46     1.16
SQLThinkRS     SELECT (5 rows)                150      94.53     0.63
.NET SqlClient INSERT (50000 rows)          50000   41250.39     0.82
SQLThinkRS     INSERT (50000 rows)          50000   32243.61     0.65
.NET SqlClient SELECT (50000 rows)            150    3608.52    24.06
SQLThinkRS     SELECT (50000 rows)            150    3918.36    26.12
.NET SqlClient SELECT under lock                1    3004.90  3004.90
SQLThinkRS     SELECT under lock                1       3.31     3.31

  Connect+Query(SELECT 1)
    SQLThinkRS                0.67 ms avg  (1x)      ** WINNER **
    .NET SqlClient            0.95 ms avg  (1.41x)

  SELECT (5 rows)
    SQLThinkRS                0.63 ms avg  (1x)      ** WINNER **
    .NET SqlClient            1.16 ms avg  (1.83x)

  INSERT (50000 rows)
    SQLThinkRS                0.65 ms avg  (1x)      ** WINNER **
    .NET SqlClient            0.82 ms avg  (1.28x)

  SELECT (50000 rows)
    .NET SqlClient           24.06 ms avg  (1x)
    SQLThinkRS               26.12 ms avg  (1.09x)

  SELECT under lock
    SQLThinkRS                3.31 ms avg  (1x)      ** WINNER **
    .NET SqlClient        3,004.90 ms avg  (906x)    BLOCKED
```

**Key improvements in v0.1.8**: SQLThinkRS now **wins 4 out of 5 benchmarks** against .NET SqlClient, with only large SELECT trailing by ~9% (well within optimization reach). Connection pooling with zero-ping validation delivers **1.41x faster** connect times. Built-in snapshot isolation provides **906x faster** reads under contention.

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
