// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIShortcuts",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AIShortcuts", targets: ["AIShortcuts"]),
    ],
    targets: [
        .target(
            name: "AIShortcutsCore"
        ),
        .executableTarget(
            name: "AIShortcuts",
            dependencies: ["AIShortcutsCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AIShortcutsCoreChecks",
            dependencies: ["AIShortcutsCore"],
            path: "Tests/AIShortcutsCoreTests"
        ),
    ]
)
