// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bssist",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Bssist", targets: ["Bssist"])
    ],
    targets: [
        .executableTarget(
            name: "Bssist",
            path: "Sources/Bssist"
        )
    ]
)
