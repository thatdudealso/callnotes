// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CallNotesCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "CallNotesCore", targets: ["CallNotesCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
    ],
    targets: [
        .target(
            name: "CallNotesCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            resources: [
                .process("Store/Migrations")
            ]
        ),
        .testTarget(
            name: "CallNotesCoreTests",
            dependencies: ["CallNotesCore"]
        ),
    ]
)
