// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MonitorAgent", targets: ["MonitorAgent"]),
        .executable(name: "MonitorControl", targets: ["MonitorControl"]),
        .executable(name: "MonitorMaintenance", targets: ["MonitorMaintenance"]),
        .executable(name: "CapabilityProbe", targets: ["CapabilityProbe"]),
        .executable(name: "Benchmark", targets: ["Benchmark"]),
        .executable(name: "MaintenanceProbe", targets: ["MaintenanceProbe"]),
        .executable(name: "MaintenanceProbeHelper", targets: ["MaintenanceProbeHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.83.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.30.0"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
    ],
    targets: [
        .target(name: "CSQLite", exclude: ["README.md"], publicHeadersPath: "include", cSettings: [
            .define("SQLITE_THREADSAFE", to: "1"),
            .define("SQLITE_OMIT_LOAD_EXTENSION"),
            .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
        ]),
        .target(name: "CMacBridge", publicHeadersPath: "include", linkerSettings: [
            .linkedFramework("IOKit"),
        ]),
        .target(name: "MonitorCore"),
        .target(name: "MacCollectors", dependencies: ["MonitorCore", "CMacBridge"]),
        .target(name: "HistoryStore", dependencies: ["MonitorCore", "CSQLite"]),
        .target(name: "MonitorIPC", dependencies: ["MonitorCore"]),
        .target(name: "MonitorServer", dependencies: ["MonitorCore", "MacCollectors", "HistoryStore", "MonitorIPC",
            .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOTLS", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Clibsodium", package: "swift-sodium")]),
        .target(name: "ProbeSupport", dependencies: ["MonitorCore", "MacCollectors", "CSQLite",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Clibsodium", package: "swift-sodium"),
        ]),
        .executableTarget(name: "MonitorAgent", dependencies: ["MonitorServer"]),
        .executableTarget(name: "MonitorMaintenance", dependencies: ["MonitorIPC"]),
        .executableTarget(name: "MonitorControl", dependencies: ["MonitorIPC"], exclude: ["Resources/Localizable.xcstrings"], resources: [.copy("Resources/native-languages.json")]),
        .executableTarget(name: "CapabilityProbe", dependencies: ["ProbeSupport"], path: "Tools/CapabilityProbe"),
        .executableTarget(name: "Benchmark", dependencies: ["ProbeSupport"], path: "Tools/Benchmark"),
        .target(name: "MaintenancePrototype", path: "Tools/MaintenanceProbe/Shared"),
        .executableTarget(name: "MaintenanceProbe", dependencies: ["MaintenancePrototype"], path: "Tools/MaintenanceProbe/Control"),
        .executableTarget(name: "MaintenanceProbeHelper", dependencies: ["MaintenancePrototype"], path: "Tools/MaintenanceProbe/Helper"),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore", "MacCollectors", "ProbeSupport", "MaintenancePrototype", "HistoryStore", "MonitorServer", "MonitorIPC", "MonitorControl"], path: "Tests/MonitorCoreTests"),
    ]
)
