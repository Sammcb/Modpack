import Foundation
import ArgumentParser

extension Modpack {
	struct Install: AsyncParsableCommand, ApiActor {
		static var configuration = CommandConfiguration(abstract: "Install modpack.")
		
		@Flag(name: .shortAndLong, help: "Print trace and debug information.")
		var verbose = false
		
		func validate() throws {
			guard FileManager.default.fileExists(atPath: ApiConfig.configFileURL.path()) else {
				throw ValidationError("'\(ApiConfig.configFileURL.lastPathComponent)' file does not exist.")
			}
			
			guard FileManager.default.fileExists(atPath: ApiConfig.lockFileURL.path()) else {
				throw ValidationError("'\(ApiConfig.lockFileURL.lastPathComponent)' file does not exist.")
			}
		}
		
		mutating func run() async throws {
			logger.logLevel = verbose ? .trace : .info
			
			try await validateConfig()
			
			let config = try ApiConfig.config
			
			let versionsString = "[\(config.versions.joined(separator: ", "))]"
			logger.info("Installing modpack for Minecraft version(s) \(versionsString)...\n")
			
			for url in config.directories.values {
				if FileManager.default.fileExists(atPath: url.path()) {
					continue
				}
				
				logger.debug("'\(url.lastPathComponent)' directory does not exist, creating...")
				try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			}
			
			let stateData = try Data(contentsOf: ApiConfig.lockFileURL)
			let state = try JSONDecoder().decode(State.self, from: stateData)
			
			try await install(from: state, config)
		}
	}
}
