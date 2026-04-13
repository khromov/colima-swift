// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ColimaSwift",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            .upToNextMinor(from: "0.4.0")
        )
    ],
    targets: [
        .executableTarget(
            name: "ColimaSwift",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ],
            path: "ColimaSwift",
            exclude: ["Info.plist", "ColimaSwift.entitlements"]
        )
    ]
)
