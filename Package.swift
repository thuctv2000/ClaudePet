// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PetMacOS",
    defaultLocalization: "en",
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
            ],
            // Assets.xcassets (app icon) only makes sense in the xcodegen app
            // build; SPM can't compile asset catalogs, so keep it out of the
            // dev build instead of warning on every compile.
            exclude: ["Resources"],
            resources: [
                .process("Localizable.xcstrings")
            ]
        )
    ]
)
