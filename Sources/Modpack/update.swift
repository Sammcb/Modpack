import Foundation
import ArgumentParser

extension Modpack {
	struct Update: AsyncParsableCommand, ApiActor {
		static var configuration = CommandConfiguration(abstract: "Update installed mods.")
		
		@Argument(help: "Mod list json file.")
		var configPath: String
		
		@Flag(name: .customShort("y"), help: "Skip installation confirmations.")
		var skipConfirmation = false
		
		@Flag(name: [.customShort("c"), .long], help: "Show changelogs for new versions.")
		var showChangelog = false
		
		@Flag(name: .customLong("r"), help: "Reinstall CurseForge mods.")
		var reloadCurseForge = false
		
		@Flag(name: .shortAndLong, help: "Print trace and debug information.")
		var verbose = false
		
		func validate() throws {
			let configFileURL = URL(fileURLWithPath: configPath)
			
			guard configFileURL.pathExtension == "json" else {
				throw ValidationError("Mod list must be a json file.")
			}
			
			guard FileManager.default.fileExists(atPath: configFileURL.path) else {
				throw ValidationError("Mod list file does not exist.")
			}
		}
		
		private func updateCurseForge(_ mod: Mod, _ reloadCurseForge: Bool) async throws {
			logger.notice("Downloading CurseForge mod \(mod.name)...")
			let saveURL = ApiConfig.modsURL.appendingPathComponent("\(mod.name).jar")
			
			if FileManager.default.fileExists(atPath: saveURL.path) && reloadCurseForge {
				logger.notice("CurseForge mod \(mod.name) already installed, reinstalling...")
				try FileManager.default.removeItem(at: saveURL)
			} else if FileManager.default.fileExists(atPath: saveURL.path) && !reloadCurseForge {
				return
			}
			
			var request = URLRequest(url: URL(string: mod.url!)!)
			request.httpMethod = "GET"
			let (downloadURL, _) = try await URLSession.shared.download(for: request)

			try FileManager.default.moveItem(at: downloadURL, to: saveURL)
		}
		
		private func update(_ mod: Mod, _ loaders: [String], _ mcVersions: [String], _ skipConfirmation: Bool, _ showChangelog: Bool, dependency: Bool = false) async throws {
			let dependencyLogModifier = dependency ? " dependency" : ""
			
			let project = try await getProject(for: mod.id)
			
			logger.info("Fetching versions for\(dependencyLogModifier) \(project.title)...")
			
			var versions: [Version] = []
			for loader in loaders {
				for mcVersion in mcVersions {
					let fetchedVersions = try await getVersion(for: mod, loader, mcVersion)
					versions.append(contentsOf: fetchedVersions)
					
					if fetchedVersions.isEmpty && versions.isEmpty {
						logger.notice("No versions of\(dependencyLogModifier) \(project.title) found for Minecraft \(mcVersion) on \(loader)")
					}
				}
			}
			
			guard let latestVersion = versions.first, let file = latestVersion.files.filter({ $0.primary }).first else {
				return
			}
			
			let saveURL = ApiConfig.modsURL.appendingPathComponent(file.filename)
			
			if FileManager.default.fileExists(atPath: saveURL.path) {
				logger.debug("Lastest version of\(dependencyLogModifier) \(project.title) already exists...")
				return
			}
			
			logger.info("A new version of\(dependencyLogModifier) \(project.title) is available [\(latestVersion.versionNumber)]")
			
			var currentFilePath: String?
			for version in versions {
				
				guard let versionFile = version.files.filter({ $0.primary }).first else {
					continue
				}
				
				let currentFileURL = ApiConfig.modsURL.appendingPathComponent(versionFile.filename)
				if FileManager.default.fileExists(atPath: currentFileURL.path) {
					currentFilePath = currentFileURL.path
					break
				}
				
				guard showChangelog, let changelog = version.changelog else {
					continue
				}
				
				logger.info("Changlog for [\(version.versionNumber)]:")
				logger.info("\(changelog.trimmingCharacters(in: .whitespacesAndNewlines))\n")
			}
			
			if !skipConfirmation {
				logger.info("Install? [y/N]")
				
				guard let answer = readLine() else {
					return
				}
				
				guard answer.lowercased() == "y" else {
					logger.warning("Skipping installation of\(dependencyLogModifier) \(project.title) [\(latestVersion.versionNumber)]")
					return
				}
			}
			
			if let currentFilePath = currentFilePath {
				logger.info("Removing old version...")
				try FileManager.default.removeItem(atPath: currentFilePath)
			}
			
			logger.info("Downloading latest version...")
			
			var request = URLRequest(url: URL(string: file.url)!)
			request.httpMethod = "GET"
			let (downloadURL, _) = try await URLSession.shared.download(for: request)
			
			try FileManager.default.moveItem(at: downloadURL, to: saveURL)
			
			logger.info("Latest version installed successfully!")
			
			for modDependency in latestVersion.dependencies ?? [] {
				guard let projectId = modDependency.projectId else {
					continue
				}
				
				let dependencyMod = Mod(name: "dependency", id: projectId, url: nil)
				try await update(dependencyMod, loaders, mcVersions, skipConfirmation, showChangelog, dependency: true)
			}
		}
		
		mutating func run() async throws {
			logger.logLevel = verbose ? .trace : .info
			
			let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			logger.info("Checking mod list for updates for Minecraft version(s) [\(config.versions.joined(separator: ", "))]")
			
			if !FileManager.default.fileExists(atPath: ApiConfig.modsURL.path) {
				logger.debug("'mods' directory does not exist, creating...")
				try FileManager.default.createDirectory(at: ApiConfig.modsURL, withIntermediateDirectories: true)
			}
			
			for mod in config.mods {
				if mod.url == nil {
					try await update(mod, config.loaders, config.versions, skipConfirmation, showChangelog, dependency: false)
				} else {
					try await updateCurseForge(mod, reloadCurseForge)
				}
			}
		}
	}
}
