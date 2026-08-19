// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WalkingPad",
    platforms: [.macOS(.v14)],
    targets: [
        // Protocol + BLE + metrics. No UI, so it is unit-testable on its own.
        .target(
            name: "WalkingPadKit",
            path: "Sources/WalkingPadKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SwiftUI app shell. Built into a .app bundle by ./build.sh
        .executableTarget(
            name: "WalkingPad",
            dependencies: ["WalkingPadKit"],
            path: "Sources/WalkingPad",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI diagnostics + protocol self-test. The CLT SDK ships no test framework,
        // so `padctl selftest` is how the protocol layer gets verified.
        .executableTarget(
            name: "padctl",
            dependencies: ["WalkingPadKit"],
            path: "Sources/padctl",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // A bare executable has no Info.plist, and CoreBluetooth aborts the process
            // unless it can find NSBluetoothAlwaysUsageDescription. Link the plist into
            // the binary's __TEXT,__info_plist section so TCC can read it.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/padctl-Info.plist",
                ])
            ]
        ),
    ]
)
