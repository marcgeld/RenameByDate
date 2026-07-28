// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RenameByDate",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "rbdate", targets: ["RenameByDate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "RenameByDate",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "RenameByDateTests",
            dependencies: ["RenameByDate"],
            resources: [.copy("Resources")]
        ),
    ]
)
