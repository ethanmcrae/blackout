// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Blackout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Blackout",
            path: "Blackout",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
