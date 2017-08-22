// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BearNanny",
    dependencies: [
        // Make sure to use the swift-4 branch (by `swift package edit SQLite` and "git co swift-4")
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.11.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "BearNanny",
            dependencies: ["SQLite"]),
    ]
)
