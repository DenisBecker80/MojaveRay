// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "MojaveRay",
    platforms: [
        .macOS(.v10_14)
    ],
    products: [
        .executable(name: "MojaveRay", targets: ["MojaveRay"])
    ],
    targets: [
        .target(
            name: "MojaveRayCore",
            dependencies: [],
            path: "Sources/MojaveRayCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "MojaveRay",
            dependencies: ["MojaveRayCore"],
            path: "Sources/MojaveRay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "MojaveRayTests",
            dependencies: ["MojaveRayCore"],
            path: "Tests/MojaveRayTests"
        )
    ]
)
