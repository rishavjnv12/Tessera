// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TorrentUI",
    platforms: [.macOS("26.0"), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "TorrentUI", targets: ["TorrentUI"]),
    ],
    targets: [
        .target(name: "TorrentUI"),
        .testTarget(name: "TorrentUITests", dependencies: ["TorrentUI"]),
    ]
)
