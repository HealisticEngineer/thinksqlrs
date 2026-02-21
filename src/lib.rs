use once_cell::sync::OnceCell;
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tiberius::{Client, Config};
use tokio::net::TcpStream;
use tokio::runtime::Runtime;
use tokio_util::compat::TokioAsyncWriteCompatExt;

type TibClient = Client<tokio_util::compat::Compat<TcpStream>>;

// Global trace flag
static TRACE_ENABLED: AtomicBool = AtomicBool::new(false);

/// Log a message to stderr when trace mode is enabled
fn trace(msg: &str) {
    if TRACE_ENABLED.load(Ordering::Relaxed) {
        eprintln!("[SQLThinkRS] {}", msg);
    }
}

/// EnableTrace turns on SQL trace output to stderr.
#[unsafe(no_mangle)]
pub extern "C" fn EnableTrace() {
    TRACE_ENABLED.store(true, Ordering::Relaxed);
    eprintln!("[SQLThinkRS] Trace enabled");
}

/// DisableTrace turns off SQL trace output.
#[unsafe(no_mangle)]
pub extern "C" fn DisableTrace() {
    eprintln!("[SQLThinkRS] Trace disabled");
    TRACE_ENABLED.store(false, Ordering::Relaxed);
}

// Global Tokio runtime for async operations
static RUNTIME: OnceCell<Runtime> = OnceCell::new();

// Global active database client
static DB_CLIENT: OnceCell<Arc<Mutex<Option<TibClient>>>> = OnceCell::new();

// Connection pool: maps connection-string -> Vec of idle clients.
// When DisconnectDb is called the client is returned here instead of being
// dropped.  ConnectDb checks the pool first and reuses an existing client
// if one is available (similar to ADO.NET connection pooling).
static CONN_POOL: OnceCell<Mutex<HashMap<String, Vec<TibClient>>>> = OnceCell::new();

// Stores the connection string used by the current active connection so that
// DisconnectDb can return the client to the correct pool bucket.
static CONN_KEY: OnceCell<Mutex<Option<String>>> = OnceCell::new();

fn get_pool() -> &'static Mutex<HashMap<String, Vec<TibClient>>> {
    CONN_POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn get_conn_key() -> &'static Mutex<Option<String>> {
    CONN_KEY.get_or_init(|| Mutex::new(None))
}

/// Get or initialize the global Tokio runtime
fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("Failed to create Tokio runtime"))
}

/// ConnectDb establishes a connection to the SQL Server database.
/// Takes a connection string and returns a C string with an error message if it fails.
/// Returns null pointer on success. The caller is responsible for freeing the error string.
///
/// Connection string format: "server=localhost;user id=sa;password=your_password;database=your_db"
///
/// # Safety
/// This function is unsafe because it dereferences a raw pointer from C.
#[unsafe(no_mangle)]
pub extern "C" fn ConnectDb(conn_str: *const c_char) -> *const c_char {
    if conn_str.is_null() {
        return create_error_string("ERROR: Connection string is null");
    }

    let c_str = unsafe { CStr::from_ptr(conn_str) };
    let conn_string = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return create_error_string("ERROR: Invalid UTF-8 in connection string"),
    };

    // Parse connection string
    let config = match parse_connection_string(conn_string) {
        Ok(cfg) => cfg,
        Err(e) => return create_error_string(&format!("ERROR: Failed to parse connection string: {}", e)),
    };

    // Initialize the global client storage
    let client_storage = DB_CLIENT.get_or_init(|| Arc::new(Mutex::new(None)));

    // Try to grab a pooled connection first (avoids TCP + TDS handshake)
    let runtime = get_runtime();
    let pooled = {
        let mut pool = get_pool().lock().unwrap();
        pool.get_mut(conn_string).and_then(|v| v.pop())
    };

    let result = if let Some(mut client) = pooled {
        // Validate the pooled connection with a lightweight ping
        trace("Pool HIT - reusing pooled connection");
        let ok = runtime.block_on(async {
            client
                .simple_query("/* ping */")
                .await
                .map_err(|e| format!("Pooled connection stale: {}", e))?
                .into_results()
                .await
                .map_err(|e| format!("Pooled connection stale: {}", e))?;
            Ok::<_, String>(client)
        });
        match ok {
            Ok(c) => Ok(c),
            Err(_) => {
                trace("Pooled connection stale - opening fresh connection");
                runtime.block_on(open_new_connection_async(config))
            }
        }
    } else {
        trace("Pool MISS - opening new connection");
        runtime.block_on(open_new_connection_async(config))
    };

    match result {
        Ok(client) => {
            let mut db = client_storage.lock().unwrap();
            *db = Some(client);
            // Remember which pool bucket to return to
            let mut key = get_conn_key().lock().unwrap();
            *key = Some(conn_string.to_string());
            std::ptr::null() // Success
        }
        Err(e) => create_error_string(&format!("ERROR: {}", e)),
    }
}

/// Open a brand-new TCP + TDS connection and set snapshot isolation.
async fn open_new_connection_async(
    config: Config,
) -> Result<TibClient, String> {
    let tcp = TcpStream::connect(config.get_addr())
        .await
        .map_err(|e| format!("Failed to connect to server: {}", e))?;

    tcp.set_nodelay(true).ok();

    let mut client = Client::connect(config, tcp.compat_write())
        .await
        .map_err(|e| format!("Failed to connect to database: {}", e))?;

    // Set snapshot isolation level once at connection time via simple_query.
    // IMPORTANT: Must NOT use client.execute() here because that wraps in
    // sp_executesql, and SET TRANSACTION ISOLATION LEVEL inside sp_executesql
    // is scoped to that procedure — it does NOT persist to the session.
    trace("EXEC: SET TRANSACTION ISOLATION LEVEL SNAPSHOT");
    client
        .simple_query("SET TRANSACTION ISOLATION LEVEL SNAPSHOT")
        .await
        .map_err(|e| format!("Failed to set snapshot isolation: {}", e))?
        .into_results()
        .await
        .map_err(|e| format!("Failed to set snapshot isolation: {}", e))?;

    trace("Connected successfully");
    Ok(client)
}

/// DisconnectDb returns the connection to the pool for reuse.
/// The underlying TCP connection stays open so the next ConnectDb with the
/// same connection string can skip the full handshake.
///
/// # Safety
/// This function is safe to call from C.
#[unsafe(no_mangle)]
pub extern "C" fn DisconnectDb() {
    if let Some(client_storage) = DB_CLIENT.get() {
        let mut db = client_storage.lock().unwrap();
        if let Some(client) = db.take() {
            // Return to pool keyed by connection string
            let key = {
                let mut k = get_conn_key().lock().unwrap();
                k.take()
            };
            if let Some(key) = key {
                trace("Returning connection to pool");
                let mut pool = get_pool().lock().unwrap();
                pool.entry(key).or_default().push(client);
            }
            // else: no key stored — just drop
        }
    }
}

/// BeginTransaction starts an explicit transaction on the active connection.
/// Returns null on success, or a C error string on failure.
/// Use this before a batch of INSERT/UPDATE/DELETE statements to avoid
/// per-statement auto-commit overhead (log flush per row).
#[unsafe(no_mangle)]
pub extern "C" fn BeginTransaction() -> *const c_char {
    let client_storage = match DB_CLIENT.get() {
        Some(cs) => cs,
        None => return create_error_string("ERROR: Database not connected."),
    };
    let runtime = get_runtime();
    let result = runtime.block_on(async {
        let mut db_guard = client_storage.lock().unwrap();
        let client = match db_guard.as_mut() {
            Some(c) => c,
            None => return Err("Database not connected.".to_string()),
        };
        trace("EXEC: BEGIN TRANSACTION");
        client
            .simple_query("BEGIN TRANSACTION")
            .await
            .map_err(|e| format!("Failed to begin transaction: {}", e))?
            .into_results()
            .await
            .map_err(|e| format!("Failed to begin transaction: {}", e))?;
        Ok(())
    });
    match result {
        Ok(()) => std::ptr::null(),
        Err(e) => create_error_string(&format!("ERROR: {}", e)),
    }
}

/// CommitTransaction commits the active explicit transaction.
/// Returns null on success, or a C error string on failure.
#[unsafe(no_mangle)]
pub extern "C" fn CommitTransaction() -> *const c_char {
    let client_storage = match DB_CLIENT.get() {
        Some(cs) => cs,
        None => return create_error_string("ERROR: Database not connected."),
    };
    let runtime = get_runtime();
    let result = runtime.block_on(async {
        let mut db_guard = client_storage.lock().unwrap();
        let client = match db_guard.as_mut() {
            Some(c) => c,
            None => return Err("Database not connected.".to_string()),
        };
        trace("EXEC: COMMIT TRANSACTION");
        client
            .simple_query("COMMIT TRANSACTION")
            .await
            .map_err(|e| format!("Failed to commit transaction: {}", e))?
            .into_results()
            .await
            .map_err(|e| format!("Failed to commit transaction: {}", e))?;
        Ok(())
    });
    match result {
        Ok(()) => std::ptr::null(),
        Err(e) => create_error_string(&format!("ERROR: {}", e)),
    }
}

/// ExecuteSql processes and executes a SQL statement.
/// Takes a C string as input, processes it, executes it on the connected DB,
/// and returns a C string with the results (JSON for SELECT) or error message.
/// The caller is RESPONSIBLE for freeing the returned C string using FreeCString.
///
/// # Safety
/// This function is unsafe because it dereferences a raw pointer from C.
#[unsafe(no_mangle)]
pub extern "C" fn ExecuteSql(input_sql: *const c_char) -> *const c_char {
    if input_sql.is_null() {
        return create_error_string("ERROR: SQL input is null");
    }

    let c_str = unsafe { CStr::from_ptr(input_sql) };
    let sql = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return create_error_string("ERROR: Invalid UTF-8 in SQL string"),
    };

    // Check if database is connected
    let client_storage = match DB_CLIENT.get() {
        Some(cs) => cs,
        None => return create_error_string("ERROR: Database not connected. Call ConnectDb first."),
    };

    let trimmed_upper_sql = sql.trim().to_uppercase();
    let is_select = trimmed_upper_sql.starts_with("SELECT")
        || trimmed_upper_sql.starts_with("WITH ")
        || (trimmed_upper_sql.starts_with("DECLARE")
            && trimmed_upper_sql.contains("SELECT"));

    // Process the SQL statement - only CREATE TABLE needs transformation
    let processed_sql = if trimmed_upper_sql.starts_with("CREATE TABLE") {
        process_create_table(sql)
    } else {
        sql.to_string()
    };

    trace(&format!("Input SQL:  {}", sql.trim()));
    if processed_sql != sql {
        trace(&format!("Processed:  {}", processed_sql.trim()));
    }
    trace(&format!("Is SELECT:  {}", is_select));

    // Execute the SQL
    let runtime = get_runtime();
    let result = runtime.block_on(async {
        let mut db_guard = client_storage.lock().unwrap();
        let client = match db_guard.as_mut() {
            Some(c) => c,
            None => return Err("Database not connected. Call ConnectDb first.".to_string()),
        };

        if is_select {
            execute_select_query(client, &processed_sql).await
        } else {
            execute_non_select(client, &processed_sql).await
        }
    });

    match result {
        Ok(Some(json)) => {
            // Return JSON results
            match CString::new(json) {
                Ok(c_string) => c_string.into_raw(),
                Err(_) => create_error_string("ERROR: Failed to create C string from JSON"),
            }
        }
        Ok(None) => std::ptr::null(), // Success for non-SELECT
        Err(e) => create_error_string(&format!("ERROR: {}", e)),
    }
}

/// FreeCString frees the memory for a C string allocated by Rust.
/// This MUST be called by the client code for any returned strings.
///
/// # Safety
/// This function is unsafe because it reconstructs a CString from a raw pointer.
/// The pointer must have been created by CString::into_raw() and must not be null.
#[unsafe(no_mangle)]
pub extern "C" fn FreeCString(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s); // Reclaim and drop
        }
    }
}

// Helper function to create error strings
fn create_error_string(msg: &str) -> *const c_char {
    match CString::new(msg) {
        Ok(c_string) => c_string.into_raw(),
        Err(_) => std::ptr::null(),
    }
}

// Parse connection string into tiberius Config
fn parse_connection_string(conn_str: &str) -> Result<Config, String> {
    let mut config = Config::new();
    
    for part in conn_str.split(';') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }

        let key_value: Vec<&str> = part.splitn(2, '=').collect();
        if key_value.len() != 2 {
            continue;
        }

        let key = key_value[0].trim().to_lowercase();
        let value = key_value[1].trim();

        match key.as_str() {
            "server" | "host" => config.host(value),
            "port" => {
                if let Ok(port) = value.parse::<u16>() {
                    config.port(port);
                }
            }
            "user id" | "uid" | "user" => config.authentication(tiberius::AuthMethod::sql_server(value, "")),
            "password" | "pwd" => {
                // Password is set with user id, need to re-set authentication
                // This is a simplified approach; you may need to store and combine user/password
            }
            "database" | "initial catalog" => config.database(value),
            "trust server certificate" => {
                if value.eq_ignore_ascii_case("true") || value == "1" {
                    config.trust_cert();
                }
            }
            _ => {}
        }
    }

    // Parse user and password together
    let mut user = String::new();
    let mut password = String::new();

    for part in conn_str.split(';') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }

        let key_value: Vec<&str> = part.splitn(2, '=').collect();
        if key_value.len() != 2 {
            continue;
        }

        let key = key_value[0].trim().to_lowercase();
        let value = key_value[1].trim();

        match key.as_str() {
            "user id" | "uid" | "user" => user = value.to_string(),
            "password" | "pwd" => password = value.to_string(),
            _ => {}
        }
    }

    if !user.is_empty() {
        config.authentication(tiberius::AuthMethod::sql_server(user, password));
    }

    Ok(config)
}

/// Process CREATE TABLE to inject primary key if not present
fn process_create_table(sql: &str) -> String {
    let upper_sql = sql.to_uppercase();
    if upper_sql.contains("PRIMARY KEY") {
        return sql.to_string();
    }

    // Find the first opening parenthesis
    if let Some(first_paren_index) = sql.find('(') {
        let primary_key_column = "ID INT PRIMARY KEY IDENTITY(1,1), ";
        let mut processed_sql = String::with_capacity(sql.len() + primary_key_column.len());
        processed_sql.push_str(&sql[..=first_paren_index]);
        processed_sql.push_str(primary_key_column);
        processed_sql.push_str(&sql[first_paren_index + 1..]);
        return processed_sql;
    }

    sql.to_string()
}

/// Process SELECT - snapshot isolation is now set at connection time,
/// so this just returns the SQL as-is (no extra round-trip needed).
#[allow(dead_code)]
fn process_select(sql: &str) -> String {
    sql.to_string()
}

/// Execute SELECT query and return JSON results.
/// Sends BEGIN TRANSACTION + SELECT + COMMIT TRANSACTION as a **single batch**
/// via simple_query, so snapshot isolation is honoured with only ONE round-trip
/// instead of three.  The result sets are iterated to find the one containing rows.
async fn execute_select_query(
    client: &mut Client<tokio_util::compat::Compat<TcpStream>>,
    sql: &str,
) -> Result<Option<String>, String> {
    // Build a single-batch string: BEGIN TRAN; SELECT …; COMMIT TRAN
    let batch = format!("BEGIN TRANSACTION; {} ; COMMIT TRANSACTION", sql.trim());
    trace(&format!("EXEC (batch): {}", batch));

    let stream = client
        .simple_query(&batch)
        .await
        .map_err(|e| format!("Query execution failed: {}", e))?;

    // simple_query can return multiple result sets (one per statement).
    // The SELECT results will be in the set that actually contains rows.
    let result_sets = stream
        .into_results()
        .await
        .map_err(|e| format!("Failed to fetch results: {}", e))?;

    // Find the first non-empty result set (the SELECT output)
    let rows = result_sets
        .into_iter()
        .find(|rs| !rs.is_empty())
        .unwrap_or_default();

    let num_rows = rows.len();
    trace(&format!("SELECT returned {} rows", num_rows));

    let mut results: Vec<serde_json::Map<String, Value>> = Vec::with_capacity(num_rows);

    for row in &rows {
        let columns = row.columns();
        let mut row_map = serde_json::Map::with_capacity(columns.len());

        for (i, column) in columns.iter().enumerate() {
            row_map.insert(column.name().to_string(), row_to_json_value(row, i));
        }

        results.push(row_map);
    }

    let json = serde_json::to_string(&results)
        .map_err(|e| format!("Failed to marshal JSON: {}", e))?;

    Ok(Some(json))
}

/// Execute non-SELECT statement using simple_query (avoids sp_executesql overhead)
async fn execute_non_select(
    client: &mut Client<tokio_util::compat::Compat<TcpStream>>,
    sql: &str,
) -> Result<Option<String>, String> {
    trace(&format!("EXEC (non-select): {}", sql.trim()));
    client
        .simple_query(sql)
        .await
        .map_err(|e| format!("SQL execution failed: {}", e))?
        .into_results()
        .await
        .map_err(|e| format!("SQL execution failed: {}", e))?;

    trace("Non-select completed OK");
    Ok(None) // Success
}

/// Convert a row value to JSON Value
fn row_to_json_value(row: &tiberius::Row, index: usize) -> Value {
    // Try different types
    if let Some(val) = row.try_get::<&str, _>(index).ok().flatten() {
        return Value::String(val.to_string());
    }
    if let Some(val) = row.try_get::<i32, _>(index).ok().flatten() {
        return Value::Number(val.into());
    }
    if let Some(val) = row.try_get::<i64, _>(index).ok().flatten() {
        return Value::Number(val.into());
    }
    if let Some(val) = row.try_get::<f64, _>(index).ok().flatten() {
        if let Some(num) = serde_json::Number::from_f64(val) {
            return Value::Number(num);
        }
    }
    if let Some(val) = row.try_get::<bool, _>(index).ok().flatten() {
        return Value::Bool(val);
    }

    Value::Null
}
