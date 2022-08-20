// swift-tools-version: 5.6
import PackageDescription

let package = Package(
	name: "Modpack",
	platforms: [.macOS(.v12)],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.1.3"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.4.4"),
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
