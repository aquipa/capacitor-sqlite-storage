import Capacitor
import Foundation


enum SQLiteLocation: String {
    case docs, libs, nosync
}

@objc(SQLitePlugin)
public class SQLitePlugin: CAPPlugin, CAPBridgedPlugin {
    
    public let identifier: String = "SQLitePlugin"
    public let jsName: String = "SQLitePlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "backgroundExecuteSqlBatch", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteDatabase", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "echo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isDatabaseOpen", returnType: CAPPluginReturnPromise),
    ]
    private let implementation = SQLite()
   
    
    public override func load() {
        CAPLog.print("Initializing SQLitePlugin")

        let fileManager = FileManager.default

        // Docs path
        if let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            CAPLog.print("Detected docs path: \(docs)")
            implementation.appDBPaths["docs"] = docs
        }

        // Library path
        if let libs = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first {
            CAPLog.print("Detected Library path: \(libs)")
            implementation.appDBPaths["libs"] = libs

            let nosync = (libs as NSString).appendingPathComponent("LocalDatabase")

            // Create LocalDatabase dir if needed
            if !fileManager.fileExists(atPath: nosync) {
                do {
                    try fileManager.createDirectory(atPath: nosync, withIntermediateDirectories: false, attributes: nil)
                    CAPLog.print("no cloud sync directory created with path: \(nosync)")
                } catch {
                    CAPLog.print("INTERNAL PLUGIN ERROR: could not create no cloud sync directory at path: \(nosync)")
                    return
                }
            } else {
                CAPLog.print("no cloud sync directory already exists at path: \(nosync)")
            }

            // Exclude from iCloud backup
            do {
                var nosyncURL = URL(fileURLWithPath: nosync)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try nosyncURL.setResourceValues(resourceValues)

                CAPLog.print("no cloud sync at path: \(nosync)")
                implementation.appDBPaths["nosync"] = nosync
            } catch {
                CAPLog.print("INTERNAL PLUGIN ERROR: error setting nobackup flag in LocalDatabase directory: \(error)")
                return
            }
        }
    }
    
    @objc func open(_ call: CAPPluginCall) {
        guard let dbName = call.getString("dbName") else {
            call.reject("Missing dbName")
            return
        }
        let location = call.getString("location") ?? "docs"

        do {
            try implementation.open(call: call, dbName: dbName, location: location)
        } catch {
            call.reject("Failed to open database", nil, error)
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        guard let dbName = call.getString("dbName") else {
            call.reject("Missing dbName")
            return
        }

        do {
            try implementation.close(call: call, dbName: dbName)
        } catch {
            call.reject("Failed to close database", nil, error)
        }
    }
    
    
    @objc func backgroundExecuteSqlBatch(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.executeSqlBatchNow(call: call)
        }
    }
    
    private func executeSqlBatchNow(call: CAPPluginCall) {
        guard let dbname = call.getString("dbName"),
              let executes = call.getArray("batch") as? [[String: Any]]
        else {
            call.reject("Invalid arguments")
            return
        }

        var results: [[String: Any]] = []

        for dict in executes {
            let result = implementation.executeSqlWithDict(dict: dict, dbname: dbname)

            if result["status"] as? String == "error" {
                results.append([
                    "type": "error",
                    "error": result["message"] ?? "Unknown error",
                    "result": result["message"] ?? "Unknown error"
                ])
            } else {
                results.append([
                    "type": "success",
                    "result": result["message"] ?? NSNull()
                ])
            }
        }

        call.resolve([
            "results": results
        ])
    }
    

    @objc func deleteDatabase(_ call: CAPPluginCall) {
        guard let dbName = call.getString("dbName") else {
            call.reject("Missing dbName")
            return
        }
        let location = call.getString("location") ?? "docs"


        do {
            try implementation.deleteDatabase(call:call, dbName: dbName, location: location)
        } catch {
            call.reject("Failed to delete database", nil, error)
        }
    }

    @objc func echo(_ call: CAPPluginCall) {
        let value = call.getString("value") ?? ""
        call.resolve(["value": value])
    }

    @objc func isDatabaseOpen(_ call: CAPPluginCall) {
        guard let dbName = call.getString("dbName") else {
            call.reject("Missing dbName")
            return
        }

        let isOpen = implementation.isDatabaseOpen(dbName: dbName)
        call.resolve(["isOpen": isOpen])
    }
}
