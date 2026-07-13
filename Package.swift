// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PetMacOS", targets: ["PetMacOS"])
    ],
    targets: [
        .executableTarget(name: "PetMacOS")
    ]
)
