import Foundation

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
	
	static let userAgent = "github.com/Sammcb/Modpack/2.1.0 (sammcb.com)"
	static let modsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appending(path: "mods")
	static let datapacksURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appending(path: "datapacks")
}

protocol ApiActor {
	var baseURLComponents: URLComponents { get }
	func avoidRateLimit(using response: HTTPURLResponse) async throws
	func getProject(for id: String) async throws -> Project
	func getVersions(for project: Project, loaders: [String], mcVersions: [String], dependencyLogModifier: String) async throws -> [Version]
}

extension ApiActor {
	var baseURLComponents: URLComponents {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "api.modrinth.com"
		components.path = "/v2/project/"
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
	
	func getProject(for id: String) async throws -> Project {
		var components = baseURLComponents
		components.path.append("\(id)")
		
		var request = URLRequest(url: components.url!)
		request.httpMethod = "GET"
		request.setValue(ApiConfig.userAgent, forHTTPHeaderField: "User-Agent")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		guard let response = response as? HTTPURLResponse else {
			throw ModpackError.responseHeaders
		}
		
		let error = try? decoder.decode(ResponseError.self, from: data)
		
		if let error {
			logger.error("\(error.description)")
			throw ModpackError.api(error.error)
		}
		
		try await avoidRateLimit(using: response)
		
		return try decoder.decode(Project.self, from: data)
	}
	
	private func getVersions(for projectId: String, _ loaders: [String], _ versions: [String]) async throws -> [Version] {
		var components = baseURLComponents
		components.path.append("\(projectId)/version")
		components.queryItems = [
			URLQueryItem(name: "loaders", value: "[\(loaders.map({ "\"\($0)\"" }).joined(separator: ","))]"),
			URLQueryItem(name: "game_versions", value: "[\(versions.map({ "\"\($0)\"" }).joined(separator: ","))]")
		]
		
		var request = URLRequest(url: components.url!)
		request.httpMethod = "GET"
		request.setValue(ApiConfig.userAgent, forHTTPHeaderField: "User-Agent")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		guard let response = response as? HTTPURLResponse else {
			throw ModpackError.responseHeaders
		}
		
		let error = try? decoder.decode(ResponseError.self, from: data)
		
		if let error {
			logger.error("\(error.description)")
			throw ModpackError.api(error.error)
		}
		
		try await avoidRateLimit(using: response)
		
		return try decoder.decode([Version].self, from: data)
	}
	
	private func match(_ version: Version, loader: String, mcVersion: String) -> Bool {
		version.loaders.contains(loader) && version.gameVersions.contains(mcVersion)
	}
	
	private func sort(project: Project, versions: [Version], loaders: [String], mcVersions: [String], _ dependencyLogModifier: String = "") -> [Version] {
		var versionsToCheck = versions
		var sortedVersions: [Version] = []
		for loader in loaders {
			for mcVersion in mcVersions {
				let matchingVersions = versionsToCheck.filter({ match($0, loader: loader, mcVersion: mcVersion) })
				versionsToCheck.removeAll(where: { match($0, loader: loader, mcVersion: mcVersion) })
				
				if matchingVersions.isEmpty && sortedVersions.isEmpty {
					logger.debug("No versions of\(dependencyLogModifier) \(project.title) found for Minecraft \(mcVersion) on \(loader)")
					continue
				}
				
				sortedVersions.append(contentsOf: matchingVersions.sorted(by: { $0.datePublished > $1.datePublished }))
			}
		}
		
		return sortedVersions
	}
	
	func getVersions(for project: Project, loaders: [String], mcVersions: [String], dependencyLogModifier: String) async throws -> [Version] {
		let versions = try await getVersions(for: project.id, loaders, mcVersions)
		return sort(project: project, versions: versions, loaders: loaders, mcVersions: mcVersions, dependencyLogModifier)
	}
}
