# PowerShell script to test the Rust SQL Server DLL

# Configuration
$DllPath = ".\target\release\sqlthinkrs.dll"
$ServerName = "localhost"
$Database = "tempdb"
$UserId = "sa"
$Password = "NeverSafe2Day!"

Write-Host "=== SQLThinkRS Rust DLL Test ===" -ForegroundColor Cyan
Write-Host ""

# Check if DLL exists
if (-not (Test-Path $DllPath)) {
    Write-Host "ERROR: DLL not found at $DllPath" -ForegroundColor Red
    Write-Host "Please run: cargo build --release" -ForegroundColor Yellow
    exit 1
}

# Resolve full path so DllImport can locate the native library
$DllFullPath = (Resolve-Path $DllPath).Path

# Define P/Invoke signatures
$signature = @"
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

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr BeginTransaction();

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr CommitTransaction();

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void EnableTrace();

    [DllImport(@"$DllFullPath", CallingConvention = CallingConvention.Cdecl)]
    public static extern void DisableTrace();

    public static string PtrToStringAndFree(IntPtr ptr) {
        if (ptr == IntPtr.Zero) {
            return null;
        }
        string result = Marshal.PtrToStringAnsi(ptr);
        FreeCString(ptr);
        return result;
    }
}
"@

Add-Type -TypeDefinition $signature

# Trace output (uncomment to debug SQL being executed)
# [SqlThinkRS]::EnableTrace()

# Helper function to execute SQL
function Invoke-SqlThinkRS {
    param([string]$Sql)
    
    $resultPtr = [SqlThinkRS]::ExecuteSql($Sql)
    if ($resultPtr -eq [IntPtr]::Zero) {
        return $null # Success for non-SELECT
    }
    
    $result = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($resultPtr)
    [SqlThinkRS]::FreeCString($resultPtr)
    
    if ($result -and $result.StartsWith("ERROR:")) {
        throw $result
    }
    
    return $result
}

try {
    # Step 1: Connect to database
    Write-Host "[1/10] Connecting to SQL Server..." -ForegroundColor Yellow
    $connString = "server=$ServerName;user id=$UserId;password=$Password;database=$Database;trust server certificate=true"
    
    $errorPtr = [SqlThinkRS]::ConnectDb($connString)
    if ($errorPtr -ne [IntPtr]::Zero) {
        $errorMsg = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPtr)
        [SqlThinkRS]::FreeCString($errorPtr)
        throw $errorMsg
    }
    Write-Host "   [OK] Connected successfully" -ForegroundColor Green
    Write-Host ""

    # Step 2: Create table (should auto-inject primary key)
    Write-Host "[2/10] Creating test table..." -ForegroundColor Yellow

    # Clean up any leftover table from a previous failed run
    Invoke-SqlThinkRS -Sql "IF OBJECT_ID('TestRustTable','U') IS NOT NULL DROP TABLE TestRustTable"

    $createTableSql = @"
CREATE TABLE TestRustTable (
    Name NVARCHAR(100),
    Age INT,
    Active BIT
)
"@
    
    Invoke-SqlThinkRS -Sql $createTableSql
    Write-Host "   [OK] Table created (with auto-injected ID primary key)" -ForegroundColor Green
    Write-Host ""

    # Step 3: Insert test data
    Write-Host "[3/10] Inserting test data..." -ForegroundColor Yellow
    $insertSql1 = "INSERT INTO TestRustTable (Name, Age, Active) VALUES ('Alice', 30, 1)"
    $insertSql2 = "INSERT INTO TestRustTable (Name, Age, Active) VALUES ('Bob', 25, 0)"
    $insertSql3 = "INSERT INTO TestRustTable (Name, Age, Active) VALUES ('Charlie', 35, 1)"
    
    Invoke-SqlThinkRS -Sql $insertSql1
    Invoke-SqlThinkRS -Sql $insertSql2
    Invoke-SqlThinkRS -Sql $insertSql3
    Write-Host "   [OK] Inserted 3 rows" -ForegroundColor Green
    Write-Host ""

    # Step 4: Select data (should auto-add SNAPSHOT isolation)
    Write-Host "[4/10] Querying data..." -ForegroundColor Yellow
    $selectSql = "SELECT * FROM TestRustTable"
    
    $jsonResult = Invoke-SqlThinkRS -Sql $selectSql
    $data = $jsonResult | ConvertFrom-Json
    
    Write-Host "   [OK] Retrieved $($data.Count) rows as JSON" -ForegroundColor Green
    Write-Host ""
    Write-Host "   Results:" -ForegroundColor Cyan
    $data | Format-Table -AutoSize
    Write-Host ""

    # Step 5: Test filtered query
    Write-Host "[5/10] Testing filtered query..." -ForegroundColor Yellow
    $filterSql = "SELECT Name, Age FROM TestRustTable WHERE Active = 1"
    
    $jsonResult = Invoke-SqlThinkRS -Sql $filterSql
    $activeUsers = $jsonResult | ConvertFrom-Json
    
    Write-Host "   [OK] Found $($activeUsers.Count) active users" -ForegroundColor Green
    $activeUsers | Format-Table -AutoSize
    Write-Host ""

    # Step 6: Test DECLARE with SELECT
    Write-Host "[6/10] Testing DECLARE with SELECT..." -ForegroundColor Yellow
    $declareSql = @"
DECLARE @MinAge INT = 28;
SELECT Name, Age FROM TestRustTable WHERE Age >= @MinAge ORDER BY Age
"@
    
    $jsonResult = Invoke-SqlThinkRS -Sql $declareSql
    $declareData = $jsonResult | ConvertFrom-Json
    
    Write-Host "   [OK] DECLARE + SELECT returned $($declareData.Count) rows (Age >= 28)" -ForegroundColor Green
    $declareData | Format-Table -AutoSize
    Write-Host ""

    # Step 7: Test DECLARE with multiple variables and computation
    Write-Host "[7/10] Testing DECLARE with multiple variables..." -ForegroundColor Yellow
    $declareMultiSql = @"
DECLARE @NameFilter NVARCHAR(50) = 'Alice';
DECLARE @AgeBonus INT = 10;
SELECT Name, Age, Age + @AgeBonus AS AgeWithBonus FROM TestRustTable WHERE Name = @NameFilter
"@
    
    $jsonResult = Invoke-SqlThinkRS -Sql $declareMultiSql
    $declareMultiData = $jsonResult | ConvertFrom-Json
    
    Write-Host "   [OK] DECLARE multi-variable returned $($declareMultiData.Count) row(s)" -ForegroundColor Green
    $declareMultiData | Format-Table -AutoSize
    Write-Host ""

    # Step 8: Test WITH (Common Table Expression)
    Write-Host "[8/10] Testing WITH (CTE) query..." -ForegroundColor Yellow
    $cteSql = @"
WITH ActiveUsers AS (
    SELECT Name, Age FROM TestRustTable WHERE Active = 1
)
SELECT Name, Age FROM ActiveUsers ORDER BY Name
"@
    
    $jsonResult = Invoke-SqlThinkRS -Sql $cteSql
    $cteData = $jsonResult | ConvertFrom-Json
    
    Write-Host "   [OK] CTE query returned $($cteData.Count) active users" -ForegroundColor Green
    $cteData | Format-Table -AutoSize
    Write-Host ""

    # Step 9: Update data
    Write-Host "[9/10] Updating data..." -ForegroundColor Yellow
    $updateSql = "UPDATE TestRustTable SET Age = 31 WHERE Name = 'Alice'"
    
    Invoke-SqlThinkRS -Sql $updateSql
    Write-Host "   [OK] Updated successfully" -ForegroundColor Green
    Write-Host ""

    # Step 10: Cleanup - Drop table
    Write-Host "[10/10] Cleaning up..." -ForegroundColor Yellow
    $dropSql = "DROP TABLE TestRustTable"
    
    Invoke-SqlThinkRS -Sql $dropSql
    Write-Host "   [OK] Table dropped" -ForegroundColor Green
    Write-Host ""

    Write-Host "=== ALL TESTS PASSED ===" -ForegroundColor Green

} catch {
    Write-Host ""
    Write-Host "TEST FAILED: $_" -ForegroundColor Red
    exit 1
} finally {
    # Always disconnect
    Write-Host ""
    Write-Host "Disconnecting..." -ForegroundColor Yellow
    [SqlThinkRS]::DisconnectDb()
    Write-Host "[OK] Disconnected" -ForegroundColor Green
}
