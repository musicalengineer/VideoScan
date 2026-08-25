// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HallieKokoroHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "kokoro-tts", targets: ["HallieKokoroHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mlalma/kokoro-ios.git", exact: "1.0.10"),
        .package(url: "https://github.com/mlalma/MisakiSwift.git", exact: "1.0.5"),
        .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.29.1"),
    ],
    targets: [
        .executableTarget(
            name: "HallieKokoroHelper",
            dependencies: [
                .product(name: "KokoroSwift", package: "kokoro-ios"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
            ]
        ),
    ]
)
