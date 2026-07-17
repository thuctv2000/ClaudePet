// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PetMacOS", targets: ["PetMacOS"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "PetMacOS",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        )
    ]
)
