// swift-tools-version: 5.9
// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "SonyReceive",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SonyReceive", targets: ["SonyReceive"])
    ],
    targets: [
        .target(
            name: "USBRegister",
            path: "Sources/USBRegister",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "SonyReceiveCore",
            dependencies: ["USBRegister"],
            path: "Sources/SonyReceiveCore"
        ),
        .executableTarget(
            name: "SonyReceive",
            dependencies: ["SonyReceiveCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "SonyReceiveCoreTests",
            dependencies: ["SonyReceiveCore"],
            path: "Tests"
        ),
    ]
)
