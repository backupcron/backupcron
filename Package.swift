// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BackupCron",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BackupCron", targets: ["BackupFlow"])
    ],
    targets: [
        .executableTarget(
            name: "BackupFlow",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "BackupFlowTests",
            dependencies: ["BackupFlow"]
        )
    ],
    swiftLanguageModes: [.v5]
)
