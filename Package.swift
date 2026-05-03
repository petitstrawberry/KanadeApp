// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KanadeApp",
    dependencies: [
        .package(url: "https://github.com/petitstrawberry/KanadeKit.git", from: "0.6.1"),
        .package(url: "https://github.com/vtourraine/AcknowList.git", from: "3.0.0"),
    ]
)
