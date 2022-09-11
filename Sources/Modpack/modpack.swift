import Foundation
import ArgumentParser

@main
struct Modpack: AsyncParsableCommand {
	static var configuration = CommandConfiguration(abstract: "A utility for managing modpacks.", version: "2.1.4", subcommands: [Update.self, Report.self])
}
