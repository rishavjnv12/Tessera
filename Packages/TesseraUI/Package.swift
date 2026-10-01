// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TesseraUI",
    platforms: [.macOS("26.0"), .iOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "TesseraUI", targets: ["TesseraUI"]),
    ],
    targets: [
        .target(name: "TesseraUI"),
        .testTarget(name: "TesseraUITests", dependencies: ["TesseraUI"]),
    ]
)
