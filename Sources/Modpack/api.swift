import Foundation
import CryptoKit

extension ISO8601DateFormatter {
	convenience init(_ formatOptions: Options) {
		self.init()
		self.formatOptions = formatOptions
	}
}

extension Formatter {
	static let iso8601withFractionalSeconds = ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])
}

extension Date {
	var iso8601withFractionalSeconds: String { return Formatter.iso8601withFractionalSeconds.string(from: self) }
}

extension String {
	var iso8601withFractionalSeconds: Date? { return Formatter.iso8601withFractionalSeconds.date(from: self) }
}

extension JSONDecoder.DateDecodingStrategy {
	static let iso8601withFractionalSeconds = custom {
		let container = try $0.singleValueContainer()
		let dateString = try container.decode(String.self)
		guard let date = Formatter.iso8601withFractionalSeconds.date(from: dateString) else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
		}
		return date
	}
}

extension JSONEncoder.DateEncodingStrategy {
	static let iso8601withFractionalSeconds = custom {
		var container = $1.singleValueContainer()
		try container.encode(Formatter.iso8601withFractionalSeconds.string(from: $0))
	}
}

struct ApiConfig {
	private init() {}
	
	static let userAgent = "github.com/Sammcb/Modpack/3.0.0 (sammcb.com)"
	static let baseURL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
	static let configFileURL = baseURL.appending(path: "mods.json5", directoryHint: .notDirectory)
	static let lockFileURL = baseURL.appending(path: "mods.lock", directoryHint: .notDirectory)
	static var json5Decoder: JSONDecoder {
		let decoder = JSONDecoder()
		decoder.allowsJSON5 = true
		return decoder
	}
}

protocol ApiActor {}

extension ApiActor {
	var baseURLComponents: URLComponents {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "api.modrinth.com"
		components.path = "/v2/"
		return components
	}
	
	private var encoder: JSONEncoder {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601withFractionalSeconds
		return encoder
	}
	
	private var decoder: JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601withFractionalSeconds
		return decoder
	}
	
	func avoidRateLimit(using response: HTTPURLResponse) async throws {
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
	
	private func get(_ url: URL) async throws -> Data {
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue(ApiConfig.userAgent, forHTTPHeaderField: "User-Agent")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		guard let response = response as? HTTPURLResponse else {
			throw ModpackError.responseHeaders
		}
		
		if let error = try? decoder.decode(ResponseError.self, from: data) {
			logger.error("\(error.description)")
			throw ModpackError.api(error.error)
		}
		
		try await avoidRateLimit(using: response)
		
		return data
	}
	
	func getProject(for id: String) async throws -> Project {
		var components = baseURLComponents
		components.path.append("project/\(id)")
		
		let data = try await get(components.url!)
		
		return try decoder.decode(Project.self, from: data)
	}
	
	private func getVersions(for projectId: String, _ loaders: [String], _ versions: [String]) async throws -> [Version] {
		var components = baseURLComponents
		components.path.append("project/\(projectId)/version")
		components.queryItems = [
			URLQueryItem(name: "loaders", value: "[\(loaders.map({ "\"\($0)\"" }).joined(separator: ","))]"),
			URLQueryItem(name: "game_versions", value: "[\(versions.map({ "\"\($0)\"" }).joined(separator: ","))]")
		]
		
		let data = try await get(components.url!)
		
		return try decoder.decode([Version].self, from: data)
	}
	
	private func match(_ version: Version, loader: String, mcVersion: String) -> Bool {
		version.loaders.contains(loader) && version.gameVersions.contains(mcVersion)
	}
	
	private func sort(versions: [Version], loaders: [String], mcVersions: [String]) -> [Version] {
		var versionsToCheck = versions
		var sortedVersions: [Version] = []
		for loader in loaders {
			for mcVersion in mcVersions {
				let matchingVersions = versionsToCheck.filter({ match($0, loader: loader, mcVersion: mcVersion) })
				versionsToCheck.removeAll(where: { match($0, loader: loader, mcVersion: mcVersion) })
				
				if matchingVersions.isEmpty && sortedVersions.isEmpty {
					logger.debug("\tNo versions found for Minecraft \(mcVersion) on \(loader)")
					continue
				}
				
				sortedVersions.append(contentsOf: matchingVersions.sorted(by: { $0.datePublished > $1.datePublished }))
			}
		}
		
		return sortedVersions
	}
	
	func getVersions(for project: Project, loaders: [String], mcVersions: [String]) async throws -> [Version] {
		let versions = try await getVersions(for: project.id, loaders, mcVersions)
		return sort(versions: versions, loaders: loaders, mcVersions: mcVersions)
	}
	
	func getVersion(for id: String) async throws -> Version {
		var components = baseURLComponents
		components.path.append("version/\(id)")
		
		let data = try await get(components.url!)
		
		return try decoder.decode(Version.self, from: data)
	}
	
	private func baseURL(for fileURL: URL, _ loaders: [String], _ config: Config) -> URL {
		// Assume mods directory if a jar file
		if fileURL.pathExtension == "jar" {
			return config.directories[.mod] ?? ApiConfig.baseURL.appending(path: "mods", directoryHint: .isDirectory)
		}
		// Assume resourcepack if "minecraft" loader
		if loaders.contains("minecraft") {
			return config.directories[.resourcepack] ?? ApiConfig.baseURL.appending(path: "resourcepacks", directoryHint: .isDirectory)
		}
		// Assume datapack if "datapack" loader
		if loaders.contains("datapack") {
			return config.directories[.datapack] ?? ApiConfig.baseURL.appending(path: "datapacks", directoryHint: .isDirectory)
		}
		// Assume shaderpack
		return config.directories[.shaderpack] ?? ApiConfig.baseURL.appending(path: "shaderpacks", directoryHint: .isDirectory)
	}
	
	func install(from state: State, _ config: Config) async throws {
		let fileHashes = Set(state.projects.values.compactMap({ $0.installed?.fileHashes }).joined())
		
		var localFileHashes: [String] = []
		
		for (urlType, url) in config.directories {
			let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
			for fileURL in files {
				// Ignore manually managed files
				if config.manual.contains(fileURL.lastPathComponent) {
					continue
				}
				
				let fileData = try Data(contentsOf: fileURL)
				let fileHash = SHA512.hash(data: fileData)
				let hashHex = fileHash.compactMap({ String(format: "%02x", $0) }).joined()
				
				// Probably a shaderpack config file
				if urlType == .shaderpack && !fileHashes.contains(hashHex) && fileURL.pathExtension == "txt" {
					continue
				}
				
				// Remove installed files not in the .lock file
				guard fileHashes.contains(hashHex) else {
					try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
					continue
				}
				
				localFileHashes.append(hashHex)
			}
		}
		
		if Set(localFileHashes) == fileHashes {
			logger.info("Already up to date!")
			return
		}
		
		logger.info("Downloading files...")
		
		let versions = state.projects.values.compactMap({ $0.installed }).filter({ !$0.fileHashes.isSubset(of: localFileHashes) })
		for installedVersion in versions {
			let version = try await getVersion(for: installedVersion.versionId)
			
			for file in version.files {
				guard installedVersion.fileHashes.contains(file.hashes.sha512) else {
					continue
				}
				
				if localFileHashes.contains(file.hashes.sha512) {
					continue
				}
				
				guard let filenameURL = URL(string: file.url) else {
					continue
				}
				
				let baseURL = baseURL(for: filenameURL, version.loaders, config)
				let saveURL = baseURL.appending(component: file.filename)
				
				logger.debug("Downloading '\(file.filename)'...")
				
				var request = URLRequest(url: URL(string: file.url)!)
				request.httpMethod = "GET"
				let (downloadURL, _) = try await URLSession.shared.download(for: request)
				try FileManager.default.moveItem(at: downloadURL, to: saveURL)
			}
		}
		
		logger.info("Done!")
	}
	
	func id(for dependency: Version.Dependency) async throws -> String? {
		if let projectId = dependency.projectId {
			return projectId
		}
		
		guard let versionId = dependency.versionId else {
			return nil
		}
		
		let version = try await getVersion(for: versionId)
		return version.projectId
	}
	
	func loaders(for type: ProjectType, _ config: Config) -> [String] {
		switch type {
		case .mod: return config.loaders
		case .datapack: return ["datapack"]
		case .resourcepack: return ["minecraft"]
		case .shaderpack: return config.shaderLoaders
		}
	}
	
	func projects(for type: ProjectType, _ config: Config) -> [String] {
		switch type {
		case .mod: return config.mods
		case .datapack: return config.datapacks
		case .resourcepack: return config.resourcepacks
		case .shaderpack: return config.shaderpacks
		}
	}
}
