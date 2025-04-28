import Capacitor
import Foundation
import SQLite3

public class SQLite {
    var openDBs = ThreadSafeDictionary<String, OpaquePointer?>()
    public var appDBPaths = NSMutableDictionary()

    public init() {
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            appDBPaths["docs"] = docs.path
        }
        if let libs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            appDBPaths["libs"] = libs.path

            // Construct nosync directory path
            var nosyncURL = libs.appendingPathComponent("LocalDatabase.nosync")
            let nosyncPath = nosyncURL.path

            if !fm.fileExists(atPath: nosyncPath) {
                try? fm.createDirectory(atPath: nosyncPath, withIntermediateDirectories: true)
            }

            // Mark nosync dir to be excluded from iCloud backup
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? nosyncURL.setResourceValues(values)

            appDBPaths["nosync"] = nosyncPath
        }
    }

    @objc public func open(call: CAPPluginCall, dbName: String, location: String) throws {
        DispatchQueue.global(qos: .userInitiated).async {
            self.openNow(call: call, dbName: dbName, location: location)
        }
    }

    func openNow(call: CAPPluginCall, dbName: String, location: String = "docs") {
        guard let dbfilename = dbName as? String else {
            call.reject("Missing database name in options")
            return
        }

        let dblocation = (location as? String) ?? "docs"

        guard let dbname = getDBPath(dbfilename, at: dblocation) else {
            call.reject("INTERNAL PLUGIN ERROR: open with database name missing")
            return
        }

        if sqlite3_threadsafe() == 0 {
            call.reject("INTERNAL PLUGIN ERROR: sqlite3_threadsafe() returns false value")
            return
        }

        if openDBs[dbfilename] != nil {
            call.reject("INTERNAL PLUGIN ERROR: database already open")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var db: OpaquePointer?

            CAPLog.print("open full db path: \(dbname)")
            if sqlite3_open(dbname, &db) != SQLITE_OK {
                DispatchQueue.main.async {
                    call.reject("Unable to open DB")
                }
                return
            }

            // Optional: SQLCipher setup here
            // if let key = options["key"] as? String {
            //     sqlite3_key(db, key, Int32(key.utf8.count))
            // }

            // Enable defensive mode

            if enable_foreign_keys(db) == SQLITE_OK {
                print("Foreign keys enabled.")
            }

            // Test read to ensure DB is usable (especially for SQLCipher)
            if sqlite3_exec(db, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK {
                self.openDBs[dbfilename] = db
                DispatchQueue.main.async {
                    call.resolve([
                        "message": "Database opened"
                    ])
                }
            } else {
                // Optional: cleanup if needed
                sqlite3_close(db)
                DispatchQueue.main.async {
                    call.reject("Unable to open DB with key")
                }
            }
        }
    }

    func getDBPath(_ dbFile: String?, at locationKey: String) -> String? {
        guard let dbFile = dbFile else {
            return nil
        }

        guard let dbDir = appDBPaths[locationKey] else {
            // INTERNAL PLUGIN ERROR
            return nil
        }

        return (dbDir as! NSString).appendingPathComponent(dbFile)
    }

    public func close(call: CAPPluginCall, dbName: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.closeNow(call: call, dbName: dbName)
        }
    }

    func closeNow(call: CAPPluginCall, dbName: String) {
        guard let dbFileName = dbName as? String else {
            CAPLog.print("No db name specified for close")
            call.reject("INTERNAL PLUGIN ERROR: You must specify database path")
            return
        }

        guard let db = openDBs[dbFileName] else {
            CAPLog.print("close: db name was not open: \(dbFileName)")
            call.reject("INTERNAL PLUGIN ERROR: Specified db was not open")
            return
        }

        CAPLog.print("close db name: \(dbFileName)")
        sqlite3_close(db)
        openDBs.removeValue(forKey: dbFileName)
        call.resolve()
    }

    public func deleteDatabase(call: CAPPluginCall, dbName: String, location: String) throws {
        DispatchQueue.global(qos: .userInitiated).async {
            self.deleteNow(call: call, dbName: dbName, location: location)
        }
    }

    func deleteNow(call: CAPPluginCall, dbName: String, location: String = "docs") {
        guard let dbFileName = dbName as? String else {
            CAPLog.print("No db name specified for delete")
            call.reject("INTERNAL PLUGIN ERROR: You must specify database path")
            return
        }

        let dblocation = location as? String ?? "docs"

        guard let dbPath = getDBPath(dbFileName, at: dblocation) else {
            CAPLog.print(
                "INTERNAL PLUGIN ERROR (NOT EXPECTED): delete with no valid database path found")
            call.reject("INTERNAL PLUGIN ERROR: delete with no valid database path found")
            return
        }

        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: dbPath) {
            CAPLog.print("delete full db path: \(dbPath)")

            do {
                try fileManager.removeItem(atPath: dbPath)
                openDBs.removeValue(forKey: dbFileName)
                call.resolve()
            } catch {
                CAPLog.print("Error deleting DB: \(error.localizedDescription)")
                call.reject("Unable to delete DB: \(error.localizedDescription)")
            }

        } else {
            CAPLog.print("delete: db was not found: \(dbPath)")
            call.reject("The database does not exist at that path")
        }
    }

    public func isDatabaseOpen(dbName: String) -> Bool {
        return openDBs[dbName] != nil
    }

    public func closeAll() {
        for (_, db) in openDBs.snapshot() {
            if let db = db {
                sqlite3_close(db)
            }
        }
        openDBs.removeAll()
    }

    public func executeSqlBatch(dbName: String, batch: [String]) throws -> [[String: Any]] {
        guard let db = openDBs[dbName] else {
            throw SQLiteError("Database not open: \(dbName)")
        }

        var results: [[String: Any]] = []

        for sql in batch {
            var stmt: OpaquePointer? = nil
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                throw captureError(from: db)
            }

            defer { sqlite3_finalize(stmt) }

            let rc = sqlite3_step(stmt)
            if rc != SQLITE_ROW && rc != SQLITE_DONE {
                throw captureError(from: db)
            }

            var result: [String: Any] = [:]

            if rc == SQLITE_ROW {
                var rowResult: [[String: Any]] = []
                repeat {
                    var row = [String: Any]()
                    let colCount = sqlite3_column_count(stmt)
                    for i in 0..<colCount {
                        let name = String(cString: sqlite3_column_name(stmt, i))
                        let type = sqlite3_column_type(stmt, i)
                        switch type {
                        case SQLITE_INTEGER:
                            row[name] = Int(sqlite3_column_int64(stmt, i))
                        case SQLITE_FLOAT:
                            row[name] = Double(sqlite3_column_double(stmt, i))
                        case SQLITE_TEXT:
                            if let cString = sqlite3_column_text(stmt, i) {
                                row[name] = String(cString: cString)
                            }
                        case SQLITE_NULL:
                            row[name] = nil
                        default:
                            row[name] = nil
                        }
                    }
                    rowResult.append(row)
                } while sqlite3_step(stmt) == SQLITE_ROW

                result["rows"] = rowResult
            }

            result["rowsAffected"] = sqlite3_changes(db)
            result["lastInsertRowId"] = sqlite3_last_insert_rowid(db)

            results.append(result)
        }

        return results
    }

    private func getDatabasePath(dbName: String, location: String = "docs") throws -> String {
        guard let base = appDBPaths[location] else {
            throw SQLiteError("Invalid database location: \(location)")
        }
        return (base as! NSString).appendingPathComponent(dbName)
    }

    private func captureError(from db: OpaquePointer?) -> SQLiteError {
        let code = sqlite3_errcode(db)
        let message = String(cString: sqlite3_errmsg(db))
        return SQLiteError("[SQLite code \(code)] \(message)")
    }

    func bindStatement(_ statement: OpaquePointer?, withArg arg: Any, at index: Int32) -> Int32 {
        var bindResult: Int32 = SQLITE_ERROR

        if arg is NSNull {
            // bind null
            bindResult = sqlite3_bind_null(statement, index)

        } else if let numberArg = arg as? NSNumber {
            let numberType = String(cString: numberArg.objCType)

            if numberType == "i" || numberType == "q" || numberType == "l" {
                bindResult = sqlite3_bind_int64(statement, index, numberArg.int64Value)
            } else {
                bindResult = sqlite3_bind_double(statement, index, numberArg.doubleValue)
            }

        } else {
            let stringArg: String

            if let str = arg as? String {
                stringArg = str
            } else {
                stringArg = String(describing: arg)
            }

            if let data = stringArg.data(using: .utf8) {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                bindResult = sqlite3_bind_text(
                    statement, index,
                    (data as NSData).bytes.bindMemory(to: Int8.self, capacity: data.count),
                    Int32(data.count), SQLITE_TRANSIENT)
            } else {
                bindResult = sqlite3_bind_null(statement, index)  // fallback
            }
        }

        return bindResult
    }

    func executeSqlWithDict(dict: [String: Any], dbname: String) -> [String: Any] {
        let dbFileName = dbname

        guard let db = openDBs[dbFileName] else {
            return errorResult("INTERNAL PLUGIN ERROR: No such database, you must open it first")
        }

        guard let sql = dict["sql"] as? String else {
            return errorResult("INTERNAL PLUGIN ERROR: You must specify a sql query to execute")
        }

        let sqlStmt = sql.utf8CString
        var error: [AnyHashable: Any]? = nil
        var statement: OpaquePointer? = nil
        var result: Int32 = 0
        var columnType: Int32 = 0
        var count: Int32 = 0
        var previousRowsAffected = Int(sqlite3_total_changes(db))
        var nowRowsAffected = 0
        var diffRowsAffected = 0
        var previousInsertId = sqlite3_last_insert_rowid(db)
        var nowInsertId: sqlite3_int64 = 0
        var keepGoing = true
        var hasInsertId = false

        let resultSet: NSMutableDictionary = NSMutableDictionary(capacity: 0)
        let resultRows: NSMutableArray = NSMutableArray(capacity: 0)
        var insertId: NSObject?
        var rowsAffected: NSObject?

        let prepareResult = sql.withCString { cString in
            sqlite3_prepare_v2(db, cString, -1, &statement, nil)
        }

        if prepareResult != SQLITE_OK {
            error = self.captureSQLiteError(fromDb: db)
            keepGoing = false
        } else if let params = dict["params"] as? [Any] {
            for (i, param) in params.enumerated() {
                result = bindStatement(statement, withArg: param, at: Int32(i + 1))
                if result != SQLITE_OK {
                    error = self.captureSQLiteError(fromDb: db)
                    keepGoing = false
                    break
                }
            }
        }

        while keepGoing {
            result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                let entry = NSMutableDictionary(capacity: 0)
                count = sqlite3_column_count(statement)

                for i in 0..<count {
                    var columnValue: AnyObject?
                    let columnName = String(cString: sqlite3_column_name(statement, i))

                    columnType = sqlite3_column_type(statement, i)
                    switch columnType {
                    case SQLITE_INTEGER:
                        columnValue = NSNumber(value: sqlite3_column_int64(statement, i))
                    case SQLITE_FLOAT:
                        columnValue = NSNumber(value: sqlite3_column_double(statement, i))
                    case SQLITE_TEXT, SQLITE_BLOB:
                        if let bytes = sqlite3_column_text(statement, i) {
                            let length = Int(sqlite3_column_bytes(statement, i))
                            columnValue = NSString(
                                bytes: bytes, length: length,
                                encoding: String.Encoding.utf8.rawValue)
                        } else {
                            columnValue = NSNull()
                        }
                    case SQLITE_NULL:
                        fallthrough
                    default:
                        columnValue = NSNull()
                    }

                    if let value = columnValue {
                        entry[columnName] = value
                    }
                }

                resultRows.add(entry)

            case SQLITE_DONE:
                nowRowsAffected = Int(sqlite3_total_changes(db))
                diffRowsAffected = nowRowsAffected - previousRowsAffected
                rowsAffected = NSNumber(value: diffRowsAffected)
                nowInsertId = sqlite3_last_insert_rowid(db)
                if diffRowsAffected > 0 && nowInsertId != 0 {
                    hasInsertId = true
                    insertId = NSNumber(value: nowInsertId)
                }
                keepGoing = false

            default:
                error = self.captureSQLiteError(fromDb: db)
                keepGoing = false
            }
        }

        sqlite3_finalize(statement)

        if error != nil {
            return errorResult(from: db!)
        }

        resultSet["rows"] = resultRows
        resultSet["rowsAffected"] = rowsAffected
        if hasInsertId {
            resultSet["insertId"] = insertId
        }

        return [
            "status": "ok",
            "message": resultSet,
        ]
    }

    // MARK: - SQLite Error Handling

    let SYNTAX_ERR_ = 5
    let QUOTA_ERR = 10
    let CONSTRAINT_ERR = 6
    let UNKNOWN_ERR = 0
    let INCLUDE_SQLITE_ERROR_INFO = true  // Toggle this as needed

    func mapSQLiteErrorCode(_ code: Int32) -> Int {
        switch code {
        case SQLITE_ERROR:
            return SYNTAX_ERR_
        case SQLITE_FULL:
            return QUOTA_ERR
        case SQLITE_CONSTRAINT:
            return CONSTRAINT_ERR
        default:
            return UNKNOWN_ERR
        }
    }

    func captureSQLiteError(fromDb db: OpaquePointer?) -> [String: Any] {
        let code = sqlite3_errcode(db)
        let webSQLCode = mapSQLiteErrorCode(code)
        let message = String(cString: sqlite3_errmsg(db))

        var error: [String: Any] = [
            "code": webSQLCode,
            "message": message,
        ]

        if INCLUDE_SQLITE_ERROR_INFO {
            let extendedCode = sqlite3_extended_errcode(db)
            error["sqliteCode"] = code
            error["sqliteExtendedCode"] = extendedCode
            error["sqliteMessage"] = message
        }

        return error
    }

    private func bind(param: Any, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        if param is NSNull {
            return sqlite3_bind_null(statement, index)
        } else if let number = param as? NSNumber {
            let numberType = String(cString: number.objCType)
            if numberType == "q" || numberType == "i" {
                return sqlite3_bind_int64(statement, index, number.int64Value)
            } else {
                return sqlite3_bind_double(statement, index, number.doubleValue)
            }
        } else {
            let text = String(describing: param)
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            return sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
        }
    }

    private func errorResult(_ message: String) -> [String: Any] {
        return [
            "status": "error",
            "message": message,
        ]
    }

    private func errorResult(from db: OpaquePointer) -> [String: Any] {
        let errorMessage = String(cString: sqlite3_errmsg(db))
        return errorResult(errorMessage)
    }

}

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) {
        self.description = description
    }
}
