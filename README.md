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

### Results Summary (150 iterations, 50,000 rows)

```
Provider         Operation               Iterations Total (ms) Avg (ms)
--------         ---------               ---------- ---------- --------
SqlServer Module Connect+Query(SELECT 1)        150     160.28     1.07
.NET SqlClient   Connect+Query(SELECT 1)        150     129.63     0.86
SQLThinkRS       Connect+Query(SELECT 1)        150      97.91     0.65
SqlServer Module SELECT (5 rows)                150     150.84     1.01
.NET SqlClient   SELECT (5 rows)                150     146.42     0.98
SQLThinkRS       SELECT (5 rows)                150      92.63     0.62
SqlServer Module INSERT (50000 rows)          50000   43013.71     0.86
.NET SqlClient   INSERT (50000 rows)          50000   40790.23     0.82
SQLThinkRS       INSERT (50000 rows)          50000   32055.98     0.64
SqlServer Module SELECT (50000 rows)            150    2466.99    16.45
.NET SqlClient   SELECT (50000 rows)            150    3351.59    22.34
SQLThinkRS       SELECT (50000 rows)            150    3875.31    25.84
SqlServer Module SELECT under lock                1    3008.25  3008.25
.NET SqlClient   SELECT under lock                1    3002.85  3002.85
SQLThinkRS       SELECT under lock                1       3.10     3.10
```

### Comparative Ranking

```
Connect+Query(SELECT 1)
  SQLThinkRS                0.65 ms avg  (1x)      ** WINNER **
  .NET SqlClient            0.86 ms avg  (1.32x)
  SqlServer Module          1.07 ms avg  (1.64x)

SELECT (5 rows)
  SQLThinkRS                0.62 ms avg  (1x)      ** WINNER **
  .NET SqlClient            0.98 ms avg  (1.58x)
  SqlServer Module          1.01 ms avg  (1.63x)

INSERT (50000 rows)
  SQLThinkRS                0.64 ms avg  (1x)      ** WINNER **
  .NET SqlClient            0.82 ms avg  (1.27x)
  SqlServer Module          0.86 ms avg  (1.34x)

SELECT (50000 rows)
  SqlServer Module         16.45 ms avg  (1x)
  .NET SqlClient           22.34 ms avg  (1.36x)
  SQLThinkRS               25.84 ms avg  (1.57x)

SELECT under lock
  SQLThinkRS                3.10 ms avg  (1x)      ** WINNER **
  .NET SqlClient        3002.85 ms avg  (969.6x)   BLOCKED
  SqlServer Module      3008.25 ms avg  (971.3x)   BLOCKED
```

### Key Takeaways

- **Connection speed**: SQLThinkRS with optimized connection pooling (no ping validation) achieves **0.65 ms** — **1.32x faster** than .NET SqlClient (0.86 ms).
- **Small SELECTs**: By sending `BEGIN TRANSACTION; SELECT; COMMIT` as a single TDS batch (one round-trip instead of three), SQLThinkRS leads at **0.62 ms** — **1.58x faster** than .NET SqlClient.
- **Bulk INSERTs**: With explicit transaction wrapping and `simple_query` (no `sp_executesql` overhead), SQLThinkRS leads at **0.64 ms/row** — **1.27x faster** than .NET SqlClient.
- **Large result sets**: At 50,000 rows, SQLThinkRS achieves **25.84 ms** vs SqlServer Module's **16.45 ms** (**1.57x** behind) — this gap is due to SqlServer Module's optimized result set parsing and type conversion paths.
- **Snapshot Isolation (the killer feature)**: When another connection holds an exclusive write lock, .NET SqlClient **blocks for 3+ seconds** (until timeout). SQLThinkRS reads the same rows in **3.10 ms** — over **969x faster** — because snapshot isolation is built in and always active.

### Latest Local Run (2026-06-15)

Environment notes:
- All three providers tested: **SqlServer PowerShell module (22.4.5.1)**, **.NET SqlClient**, and **SQLThinkRS v0.1.10**.
- Run command used secure transport with explicit local self-signed override: `-TrustServerCertificate $true`.
- Includes all performance optimizations: connection pool ping removal, column type caching for large result sets.

```
Provider         Operation               Iterations Total (ms) Avg (ms)
--------         ---------               ---------- ---------- --------
SqlServer Module Connect+Query(SELECT 1)        150     160.28     1.07
.NET SqlClient   Connect+Query(SELECT 1)        150     129.63     0.86
SQLThinkRS       Connect+Query(SELECT 1)        150      97.91     0.65
SqlServer Module SELECT (5 rows)                150     150.84     1.01
.NET SqlClient   SELECT (5 rows)                150     146.42     0.98
SQLThinkRS       SELECT (5 rows)                150      92.63     0.62
SqlServer Module INSERT (50000 rows)          50000   43013.71     0.86
.NET SqlClient   INSERT (50000 rows)          50000   40790.23     0.82
SQLThinkRS       INSERT (50000 rows)          50000   32055.98     0.64
SqlServer Module SELECT (50000 rows)            150    2466.99    16.45
.NET SqlClient   SELECT (50000 rows)            150    3351.59    22.34
SQLThinkRS       SELECT (50000 rows)            150    3875.31    25.84
SqlServer Module SELECT under lock                1    3008.25  3008.25
.NET SqlClient   SELECT under lock                1    3002.85  3002.85
SQLThinkRS       SELECT under lock                1       3.10     3.10

  Connect+Query(SELECT 1)
    SQLThinkRS                0.65 ms avg  (1x)      ** WINNER **
    .NET SqlClient            0.86 ms avg  (1.32x)
    SqlServer Module          1.07 ms avg  (1.64x)

  SELECT (5 rows)
    SQLThinkRS                0.62 ms avg  (1x)      ** WINNER **
    .NET SqlClient            0.98 ms avg  (1.58x)
    SqlServer Module          1.01 ms avg  (1.63x)

  INSERT (50000 rows)
    SQLThinkRS                0.64 ms avg  (1x)      ** WINNER **
    .NET SqlClient            0.82 ms avg  (1.27x)
    SqlServer Module          0.86 ms avg  (1.34x)

  SELECT (50000 rows)
    SqlServer Module         16.45 ms avg  (1x)
    .NET SqlClient           22.34 ms avg  (1.36x)
    SQLThinkRS               25.84 ms avg  (1.57x)

  SELECT under lock
    SQLThinkRS                3.10 ms avg  (1x)      ** WINNER **
    .NET SqlClient        3002.85 ms avg  (969.6x)   BLOCKED
    SqlServer Module      3008.25 ms avg  (971.3x)   BLOCKED
```

**Key improvements in v0.1.10**: SQLThinkRS now **wins 4 out of 5 benchmarks** across all three providers, with only large SELECT trailing SqlServer Module by ~57% (due to SqlServer Module's optimized result set parsing). Connection pooling with zero-ping validation delivers **1.32x faster** connect times than .NET SqlClient. Built-in snapshot isolation provides **969x faster** reads under contention.

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
