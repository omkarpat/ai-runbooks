// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Runbooks",
    platforms: [.macOS(.v14)],   // 14 = @Observable floor; mic capture is 15+ (guarded)
    targets: [
        .executableTarget(
            name: "Runbooks",
            path: "Sources/Runbooks"
        )
    ],
    swiftLanguageModes: [.v5]
)
