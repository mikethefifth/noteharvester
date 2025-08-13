// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoteHarvester",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "NoteHarvester",
            targets: ["NoteHarvester"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
        .package(url: "https://github.com/danielsaidi/EPUBKit.git", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "NoteHarvester",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "EPUBKit", package: "EPUBKit")
            ],
            path: "NoteHarvester"
        ),
        .testTarget(
            name: "NoteHarvesterTests",
            dependencies: ["NoteHarvester"],
            path: "NoteHarvesterTests"
        )
    ]
)