// swift-tools-version: 5.7
import PackageDescription

let package = Package(
	name: "Modpack",
	platforms: [.macOS(.v13)],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.2"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.5.2"),
	],
	targets: [
		.executableTarget(
			name: "Modpack",
			dependencies: [
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				.product(name: "Logging", package: "swift-log")
			]),
	]
)
