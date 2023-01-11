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
		
		@Flag(name: .shortAndLong, help: "Print trace and debug information.")
		var verbose = false
		
		func validate() throws {
			let configFileURL = URL(fileURLWithPath: configPath)
			
			guard configFileURL.pathExtension == "json" else {
				throw ValidationError("Mod list must be a json file.")
			}
			
			guard FileManager.default.fileExists(atPath: configPath) else {
				throw ValidationError("Mod list file does not exist.")
			}
		}
		
		private func unzip(at saveURL: URL) throws {
			let unzipPath = "/usr/bin/unzip"
			
			guard FileManager.default.isExecutableFile(atPath: unzipPath) else {
				logger.notice("'\(unzipPath)' does not appear to contain the 'unzip' executable or does not exist. The downloaded datapack will need to be unzipped manually.")
				return
			}
			
			let unzip = Process()
			unzip.executableURL = URL(filePath: unzipPath)
			unzip.arguments = [
				"-qq",
				saveURL.path(percentEncoded: false),
				"-d",
				saveURL.deletingPathExtension().path(percentEncoded: false)
			]
			
			try unzip.run()
			unzip.waitUntilExit()
			
			try FileManager.default.removeItem(at: saveURL)
			
			if unzip.terminationStatus == 0 {
				logger.info("Latest version installed successfully!")
			} else {
				logger.error("Unzip failed.")
			}
		}
		
		private func update(_ configProject: Config.Project, _ loaders: [String], _ mcVersions: [String], _ ignoreMods: [Config.Project], _ skipConfirmation: Bool, _ showChangelog: Bool, dependency: Bool = false) async throws {
			let dependencyLogModifier = dependency ? " dependency" : ""
			
			let project = try await getProject(for: configProject.id)
			
			if ignoreMods.contains(where: { $0.id == project.id }) {
				logger.debug("Ignoring\(dependencyLogModifier) \(project.title)...")
				return
			}
			
			logger.info("Fetching versions for\(dependencyLogModifier) \(project.title)...")
			
			let versions = try await getVersions(for: project, loaders: loaders, mcVersions: mcVersions, dependencyLogModifier: dependencyLogModifier)
			
			guard let latestVersion = versions.first else {
				return
			}
			
			let files = latestVersion.files.count > 1 ? latestVersion.files.filter({ $0.primary }) : latestVersion.files
			
			guard let file = files.first else {
				return
			}
			
			let isDatapack = loaders.contains("datapack")
			let baseURL = isDatapack ? ApiConfig.datapacksURL : ApiConfig.modsURL
			
			let saveURL = baseURL.appendingPathComponent(file.filename)
			
			let checkSaveURL = isDatapack ? saveURL.deletingPathExtension() : saveURL
			if FileManager.default.fileExists(atPath: checkSaveURL.path(percentEncoded: false)) {
				logger.debug("Lastest version of\(dependencyLogModifier) \(project.title) already exists...")
				return
			}
			
			logger.info("A new version of\(dependencyLogModifier) \(project.title) is available [\(latestVersion.versionNumber)]")
			
			var currentFileURL: URL?
			for version in versions {
				guard let versionFile = version.files.filter({ $0.primary }).first else {
					continue
				}
				
				var checkFileURL = baseURL.appendingPathComponent(versionFile.filename)
				if isDatapack {
					checkFileURL.deletePathExtension()
				}
				if FileManager.default.fileExists(atPath: checkFileURL.path(percentEncoded: false)) {
					currentFileURL = checkFileURL
					break
				}
				
				guard showChangelog, let changelog = version.changelog else {
					continue
				}
				
				logger.info("Changlog for [\(version.versionNumber)]:")
				logger.info("\(changelog.trimmingCharacters(in: .whitespacesAndNewlines))\n")
			}
			
			if !skipConfirmation {
				logger.info("Update\(dependencyLogModifier) \(project.title)? [y/N]")
				
				guard let answer = readLine() else {
					return
				}
				
				guard answer.lowercased() == "y" else {
					logger.warning("Skipping update of\(dependencyLogModifier) \(project.title) [\(latestVersion.versionNumber)]")
					return
				}
			}
			
			if let currentFileURL {
				logger.info("Removing old version...")
				try FileManager.default.removeItem(at: currentFileURL)
			}
			
			logger.info("Downloading latest version...")
			
			var request = URLRequest(url: URL(string: file.url)!)
			request.httpMethod = "GET"
			let (downloadURL, _) = try await URLSession.shared.download(for: request)
			
			try FileManager.default.moveItem(at: downloadURL, to: saveURL)
			
			if isDatapack {
				try unzip(at: saveURL)
			} else {
				logger.info("Latest version installed successfully!")
			}
			
			for modDependency in latestVersion.dependencies?.filter({ $0.dependencyType == .required }) ?? [] {
				guard let projectId = modDependency.projectId else {
					continue
				}
				
				let dependencyMod = Config.Project(name: "", id: projectId)
				try await update(dependencyMod, loaders, mcVersions, ignoreMods, skipConfirmation, showChangelog, dependency: true)
			}
		}
		
		mutating func run() async throws {
			logger.logLevel = verbose ? .trace : .info
			
			let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			let versionsString = "[\(config.versions.joined(separator: ", "))]"
			logger.info("Checking projects for updates for Minecraft version(s) \(versionsString)")
			
			for url in [ApiConfig.modsURL, ApiConfig.datapacksURL] {
				if FileManager.default.fileExists(atPath: url.path()) {
					continue
				}
				
				logger.debug("'\(url.lastPathComponent)' directory does not exist, creating...")
				try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			}
			
			logger.info("Checking mods for \(versionsString)...")
			for mod in config.mods {
				try await update(mod, config.loaders, config.versions, config.ignore, skipConfirmation, showChangelog)
			}
			
			logger.info("Checking datapacks for \(versionsString)...")
			for datapack in config.datapacks {
				try await update(datapack, ["datapack"], config.versions, config.ignore, skipConfirmation, showChangelog)
			}
		}
	}
}
