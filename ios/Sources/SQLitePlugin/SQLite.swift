import Foundation

@objc public class SQLite: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
