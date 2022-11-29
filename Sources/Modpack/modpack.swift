import Foundation
import ArgumentParser

@main
struct Modpack: AsyncParsableCommand {
	static var configuration = CommandConfiguration(abstract: "A utility for managing modpacks.", version: "2.3.0", subcommands: [Update.self, Report.self])
}
