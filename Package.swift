// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "CompassCore",
  platforms: [.iOS("27.0")],
  products: [.library(name: "CompassCore", targets: ["CompassCore"])],
  targets: [
    .target(name: "CompassCore", swiftSettings: [.treatAllWarnings(as: .error)]),
    .testTarget(
      name: "CompassCoreTests", dependencies: ["CompassCore"],
      swiftSettings: [.treatAllWarnings(as: .error)]),
  ],
  swiftLanguageModes: [.v6]
)
