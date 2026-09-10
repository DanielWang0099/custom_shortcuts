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
        .target(
            name: "AIShortcutsRendering",
            dependencies: ["AIShortcutsCore"],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "AIShortcuts",
            dependencies: ["AIShortcutsCore", "AIShortcutsRendering"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
            ]
        ),
        .executableTarget(
            name: "AIShortcutsCoreChecks",
            dependencies: ["AIShortcutsCore"],
            path: "Tests/AIShortcutsCoreTests"
        ),
        .executableTarget(
            name: "AIShortcutsRenderingChecks",
            dependencies: ["AIShortcutsCore", "AIShortcutsRendering"],
            path: "Tests/AIShortcutsRenderingChecks",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
