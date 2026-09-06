// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhereFilm",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WhereFilmCore", targets: ["WhereFilmCore"]),
        .library(name: "WhereFilmML", targets: ["WhereFilmML"]),
        .library(name: "WhereFilmIndex", targets: ["WhereFilmIndex"]),
        .library(name: "WhereFilmSearch", targets: ["WhereFilmSearch"]),
        .executable(name: "wherefilm", targets: ["WhereFilmCLI"]),
        .executable(name: "wherefilm-vision-helper", targets: ["WhereFilmVisionHelper"]),
        .executable(name: "WhereFilmApp", targets: ["WhereFilmApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/unum-cloud/usearch.git", from: "2.20.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        // Speaker diarization. Apache-2.0 SDK over Core ML models; the pyannote
        // weights it fetches are CC-BY-4.0. Apple silicon only, which is why
        // everything that touches it degrades rather than requires it.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "WhereFilmCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "WhereFilmML",
            dependencies: [
                "WhereFilmCore",
                .product(name: "USearch", package: "usearch"),
            ]
        ),
        .target(
            name: "WhereFilmIndex",
            dependencies: [
                "WhereFilmCore", "WhereFilmML",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "WhereFilmSearch",
            dependencies: ["WhereFilmCore", "WhereFilmML"]
        ),
        // Deliberately depends on nothing of ours: it is a disposable process
        // that runs one Vision request and answers over a pipe, so it must not
        // be able to grow a database, a model or an opinion.
        .executableTarget(name: "WhereFilmVisionHelper"),
        .executableTarget(
            name: "WhereFilmCLI",
            dependencies: [
                "WhereFilmCore", "WhereFilmML", "WhereFilmIndex", "WhereFilmSearch",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "WhereFilmApp",
            dependencies: ["WhereFilmCore", "WhereFilmML", "WhereFilmIndex", "WhereFilmSearch"]
        ),
        .testTarget(
            name: "WhereFilmTests",
            dependencies: ["WhereFilmCore", "WhereFilmML", "WhereFilmIndex", "WhereFilmSearch"]
        ),
    ]
)
