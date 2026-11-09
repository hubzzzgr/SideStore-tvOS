// swift-tools-version: 5.9
import PackageDescription
import Foundation

// CI can supply the checksum-verified upstream release through GitHub's asset
// API when anonymous release redirects fail. Local Xcode uses normal SwiftPM.
let verifiedBinary = FileManager.default.fileExists(atPath:
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Vendor/OpenSSL.xcframework").path)
var dependencies: [Package.Dependency] = [.package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0")]
if !verifiedBinary { dependencies.append(.package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", exact: "3.6.5000")) }
var targets: [Target] = [
    .target(name: "TVPairTLS", dependencies: verifiedBinary ? [.target(name: "OpenSSL")] : [.product(name: "OpenSSL", package: "OpenSSL-Package")]),
    .target(name: "TVPairCore", dependencies: ["BigInt", "TVPairTLS"]),
    .testTarget(name: "TVPairCoreTests", dependencies: ["TVPairCore", "BigInt"], resources: [.copy("Fixtures")])
]
if verifiedBinary { targets.append(.binaryTarget(name: "OpenSSL", path: "Vendor/OpenSSL.xcframework")) }

let package = Package(
    name: "TVPairCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TVPairCore", targets: ["TVPairCore"])],
    dependencies: dependencies,
    targets: targets
)
