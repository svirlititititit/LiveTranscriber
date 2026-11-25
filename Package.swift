// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LessonCore",
    products: [
        .library(name: "LessonCore", targets: ["LessonCore"])
    ],
    targets: [
        .target(name: "LessonCore"),
        .testTarget(name: "LessonCoreTests", dependencies: ["LessonCore"])
    ]
)
