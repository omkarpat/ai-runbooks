// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Runbooks",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Runbooks",
            path: "Sources/Runbooks"
        )
    ],
    swiftLanguageModes: [.v5]
)
