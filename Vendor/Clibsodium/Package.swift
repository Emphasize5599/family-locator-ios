// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clibsodium",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Clibsodium", targets: ["Clibsodium"])],
    targets: [.binaryTarget(name: "Clibsodium", path: "Clibsodium.xcframework")]
)
