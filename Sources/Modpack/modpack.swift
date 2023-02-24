import Foundation
import ArgumentParser

@main
struct Modpack: AsyncParsableCommand {
	static var configuration = CommandConfiguration(abstract: "A utility for managing modpacks.", version: "4.0.1", subcommands: [Update.self, Report.self, Install.self])
}
