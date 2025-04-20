// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorSqliteStorage",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "CapacitorSqliteStorage",
            targets: ["SQLitePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "SQLitePlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/SQLitePlugin"),
        .testTarget(
            name: "SQLitePluginTests",
            dependencies: ["SQLitePlugin"],
            path: "ios/Tests/SQLitePluginTests")
    ]
)