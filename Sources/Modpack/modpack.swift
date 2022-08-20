import Foundation
import ArgumentParser
import Logging

struct ModpackLogHandler: LogHandler {
	enum Color: String {
		case gray = "7"
		case blue = "33"
		case green = "34"
		case yellow = "11"
		case red = "9"
		case purple = "13"
	}
	
	enum Mode: String {
		case none = ""
		case reset = "0"
		case bold = "1"
	}
	
	let label: String
	var logLevel: Logger.Level = .info
	var metadata: Logger.Metadata = [:]
	
	subscript(metadataKey key: String) -> Logger.Metadata.Value? {
		get {
			metadata[key]
		}
		set {
			metadata[key] = newValue
		}
	}
	
	init(label: String) {
		self.label = label
	}
	
	private func mode(for level: Logger.Level) -> Mode {
		switch level {
		case .trace: return .none
		case .debug: return .none
		case .info: return .bold
		case .notice: return .none
		case .warning: return .bold
		case .error: return .bold
		case .critical: return .bold
		}
	}
	
	private func style(for level: Logger.Level, _ mode: Mode) -> String {
		let escape = "\u{001B}[38;5;"
		let modeSequence = mode == .none ? "" : "\u{001B}[\(mode.rawValue)m"
		switch level {
		case .trace: return "\(escape)\(Color.gray.rawValue)m\(modeSequence)"
		case .debug: return "\(escape)\(Color.blue.rawValue)m\(modeSequence)"
		case .info: return "\(escape)\(Color.green.rawValue)m\(modeSequence)"
		case .notice: return "\(escape)\(Color.yellow.rawValue)m\(modeSequence)"
		case .warning: return "\(escape)\(Color.yellow.rawValue)m\(modeSequence)"
		case .error: return "\(escape)\(Color.red.rawValue)m\(modeSequence)"
		case .critical: return "\(escape)\(Color.purple.rawValue)m\(modeSequence)"
		}
	}
	
	func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
		let mode = mode(for: level)
		let style = style(for: level, mode)
		print("\(style)\(message)\u{001B}[m")
	}
}

var logger = Logger(label: "com.sammcb.modpack", factory: ModpackLogHandler.init)

struct Mod: Codable {
	let name: String
	let id: String
	let url: String?
}

struct Config: Codable {
	let loader: String
	let versions: [String]
	let mods: [Mod]
}

struct Project: Codable {
	let title: String
}

struct Version: Codable {
	struct Dependency: Codable {
		let version_id: String?
		let project_id: String?
		let dependency_type: String
	}
	
	struct File: Codable {
		let url: String
		let filename: String
		let primary: Bool
	}
	
	let version_number: String
	let changelog: String?
	let dependencies: [Dependency]?
	let files: [File]
}

struct ResponseError: Codable {
	let error: String
	let description: String
}

enum ModpackError: Error {
	case responseHeaders
	case api(_ error: String)
}

@main
struct Modpack: AsyncParsableCommand {
	static var configuration = CommandConfiguration(abstract: "A utility for managing modpacks.", version: "2.1.0", subcommands: [Update.self, Report.self])
	
	private static let modsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("mods")
	
	private static let userAgent = "github.com/Sammcb/Modpack/2.1.0 (sammcb.com)"
	
	private static var baseURLComponents: URLComponents {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "api.modrinth.com"
		components.path = "/v2/project/"
		return components
	}
	
	private static func avoidRateLimit(using response: HTTPURLResponse) async throws {
		guard let requestsRemainingString = response.value(forHTTPHeaderField: "x-ratelimit-remaining") else {
			return
		}
		
		guard let requestsRemaining = Int(requestsRemainingString), requestsRemaining < 3 else {
			return
		}
		
		guard let timeRemainingString = response.value(forHTTPHeaderField: "x-ratelimit-reset") else {
			return
		}
		
		guard let timeRemaining = UInt64(timeRemainingString) else {
			return
		}
		
		let buffer: UInt64 = 1
		
		let waitTime = timeRemaining + buffer
		
		logger.notice("Request limit reached. Waiting \(waitTime)s for limit reset...")
		try await Task.sleep(nanoseconds: 1000000000 * waitTime)
	}
	
	private static func getProject(for id: String) async throws -> Project {
		var components = Modpack.baseURLComponents
		components.path.append("\(id)")
		
		var request = URLRequest(url: components.url!)
		request.httpMethod = "GET"
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		guard let response = response as? HTTPURLResponse else {
			throw ModpackError.responseHeaders
		}
		
		let error = try? JSONDecoder().decode(ResponseError.self, from: data)
		
		if let error = error {
			logger.error("\(error.description)")
			throw ModpackError.api(error.error)
		}
		
		try await avoidRateLimit(using: response)
		
		return try JSONDecoder().decode(Project.self, from: data)
	}
	
	private static func getVersion(for projectId: String, _ loader: String, _ version: String) async throws -> [Version] {
		var components = Modpack.baseURLComponents
		components.path.append("\(projectId)/version")
		components.queryItems = [
			URLQueryItem(name: "loaders", value: "[\"\(loader)\"]"),
			URLQueryItem(name: "game_versions", value: "[\"\(version)\"]")
		]
		
		var request = URLRequest(url: components.url!)
		request.httpMethod = "GET"
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		guard let response = response as? HTTPURLResponse else {
			throw ModpackError.responseHeaders
		}
		
		let error = try? JSONDecoder().decode(ResponseError.self, from: data)
		
		if let error = error {
			logger.error("\(error.description)")
			throw ModpackError.api(error.error)
		}
		
		try await avoidRateLimit(using: response)
		
		return try JSONDecoder().decode([Version].self, from: data)
	}
	
	private static func getVersion(for mod: Mod, _ loader: String, _ version: String) async throws -> [Version] {
		try await getVersion(for: mod.id, loader, version)
	}
	
	struct Report: AsyncParsableCommand {
		struct ModReport {
			let id: String
			let name: String
			let valid: Bool
			let dependency: Bool
		}
		
		static var configuration = CommandConfiguration(abstract: "Check modpack compatibility for a specified Minecraft version.")
		
		@Argument(help: "Mod list json file.")
		var configPath: String
		
		@Argument(help: "Minecraft version to check compatibility with.")
		var version: String
		
		func validate() throws {
			let configFileURL = URL(fileURLWithPath: configPath)
			
			guard configFileURL.pathExtension == "json" else {
				throw ValidationError("Mod list must be a json file.")
			}
			
			guard FileManager.default.fileExists(atPath: configFileURL.path) else {
				throw ValidationError("Mod list file does not exist.")
			}
		}
		
		private static func report(_ mod: Mod, _ loader: String, _ version: String, checkedMods: [String], dependency: Bool = false) async throws -> [ModReport] {
			if checkedMods.contains(mod.id) {
				return []
			}
			
			let project = try await Modpack.getProject(for: mod.id)
			let versions = try await Modpack.getVersion(for: mod, loader, version)
			
			guard let validVersion = versions.first else {
				return [ModReport(id: mod.id, name: project.title, valid: false, dependency: dependency)]
			}
			
			var modReport = [ModReport(id: mod.id, name: project.title, valid: true, dependency: dependency)]
			for modDependency in validVersion.dependencies ?? [] {
				guard let projectId = modDependency.project_id else {
					continue
				}
				
				let dependencyMod = Mod(name: "dependency", id: projectId, url: nil)
				let dependencyReports = try await report(dependencyMod, loader, version, checkedMods: checkedMods + [mod.id], dependency: true)
				
				modReport.append(contentsOf: dependencyReports)
			}
			
			return modReport
		}
		
		mutating func run() async throws {
			logger.logLevel = .info
			
			let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			logger.info("Generating report for Minecraft version \(version)...")
			
			var modReports: [ModReport] = []
			for mod in config.mods where mod.url == nil {
				let modReport = try await Report.report(mod, config.loader, version, checkedMods: modReports.map({ $0.id }))
				modReports.append(contentsOf: modReport)
			}
			
			let readyCount = modReports.filter({ $0.valid }).count
			logger.info("Total")
			logger.info("[\(readyCount)/\(modReports.count)] support \(version)\n")
			logger.notice("Mods not compatible:\n\(modReports.filter({ !$0.valid }).map({ $0.name }).joined(separator: "\n"))\n")
			let dependencyReadyCount = modReports.filter({ $0.valid && $0.dependency }).count
			let dependencyCount = modReports.filter({ $0.dependency }).count
			logger.info("Dependency")
			logger.info("[\(dependencyReadyCount)/\(dependencyCount)] support \(version)\n")
			logger.warning("CurseForge mods need to be checked manually.")
		}
	}
	
	struct Update: AsyncParsableCommand {
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
		
		private static func updateCurseForge(_ mod: Mod, _ reloadCurseForge: Bool) async throws {
			logger.notice("Downloading CurseForge mod \(mod.name)...")
			let saveURL = modsURL.appendingPathComponent("\(mod.name).jar")
			
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
		
		private static func update(_ mod: Mod, _ loader: String, _ mcVersions: [String], _ skipConfirmation: Bool, _ showChangelog: Bool, dependency: Bool = false) async throws {
			let dependencyLogModifier = dependency ? " dependency" : ""
			
			let project = try await Modpack.getProject(for: mod.id)
			
			logger.info("Fetching versions for\(dependencyLogModifier) \(project.title)...")
			
			var versions: [Version] = []
			for mcVersion in mcVersions {
				versions = try await Modpack.getVersion(for: mod, loader, mcVersion)
				
				guard versions.isEmpty else {
					break
				}
				
				logger.notice("No versions of\(dependencyLogModifier) \(project.title) found for Minecraft \(mcVersion)")
			}
			
			guard let latestVersion = versions.first, let file = latestVersion.files.filter({ $0.primary }).first else {
				return
			}
			
			let saveURL = modsURL.appendingPathComponent(file.filename)
			
			if FileManager.default.fileExists(atPath: saveURL.path) {
				logger.debug("Lastest version of\(dependencyLogModifier) \(project.title) already exists...")
				return
			}
			
			logger.info("A new version of\(dependencyLogModifier) \(project.title) is available [\(latestVersion.version_number)]")
			
			var currentFilePath: String?
			for version in versions {
				
				guard let versionFile = version.files.filter({ $0.primary }).first else {
					continue
				}
				
				let currentFileURL = modsURL.appendingPathComponent(versionFile.filename)
				if FileManager.default.fileExists(atPath: currentFileURL.path) {
					currentFilePath = currentFileURL.path
					break
				}
				
				guard showChangelog, let changelog = version.changelog else {
					continue
				}
				
				logger.info("Changlog for [\(version.version_number)]:")
				logger.info("\(changelog.trimmingCharacters(in: .whitespacesAndNewlines))\n")
			}
			
			if !skipConfirmation {
				logger.info("Install? [y/N]")
				
				guard let answer = readLine() else {
					return
				}
				
				guard answer.lowercased() == "y" else {
					logger.warning("Skipping installation of\(dependencyLogModifier) \(project.title) [\(latestVersion.version_number)]")
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
				guard let projectId = modDependency.project_id else {
					continue
				}
				
				let dependencyMod = Mod(name: "dependency", id: projectId, url: nil)
				try await update(dependencyMod, loader, mcVersions, skipConfirmation, showChangelog, dependency: true)
			}
		}
		
		mutating func run() async throws {
			logger.logLevel = verbose ? .trace : .info
			
			let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			logger.info("Checking mod list for updates for Minecraft version(s) [\(config.versions.joined(separator: ", "))]")
			
			if !FileManager.default.fileExists(atPath: Modpack.modsURL.path) {
				logger.debug("'mods' directory does not exist, creating...")
				try FileManager.default.createDirectory(at: Modpack.modsURL, withIntermediateDirectories: true)
			}
			
			for mod in config.mods {
				if mod.url == nil {
					try await Update.update(mod, config.loader, config.versions, skipConfirmation, showChangelog, dependency: false)
				} else {
					try await Update.updateCurseForge(mod, reloadCurseForge)
				}
			}
		}
	}
}
