import Foundation

struct ApiConfig {
	private init() {}
	
	static let userAgent = "github.com/Sammcb/Modpack/2.1.0 (sammcb.com)"
	static let modsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("mods")
}

protocol ApiActor {
	var baseURLComponents: URLComponents { get }
	func avoidRateLimit(using response: HTTPURLResponse) async throws
	func getProject(for id: String) async throws -> Project
	func getVersion(for projectId: String, _ loader: String, _ version: String) async throws -> [Version]
	func getVersion(for mod: Mod, _ loader: String, _ version: String) async throws -> [Version]
}

extension ApiActor {
	var baseURLComponents: URLComponents {
		var components = URLComponents()
		components.scheme = "https"
		components.host = "api.modrinth.com"
		components.path = "/v2/project/"
		return components
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
		
		let error = try? JSONDecoder().decode(ResponseError.self, from: data)
		
		if let error = error {
			logger.error("\(error.description)")
			throw ModpackError.api(error.error)
		}
		
		try await avoidRateLimit(using: response)
		
		return try JSONDecoder().decode(Project.self, from: data)
	}
	
	func getVersion(for projectId: String, _ loader: String, _ version: String) async throws -> [Version] {
		var components = baseURLComponents
		components.path.append("\(projectId)/version")
		components.queryItems = [
			URLQueryItem(name: "loaders", value: "[\"\(loader)\"]"),
			URLQueryItem(name: "game_versions", value: "[\"\(version)\"]")
		]
		
		var request = URLRequest(url: components.url!)
		request.httpMethod = "GET"
		request.setValue(ApiConfig.userAgent, forHTTPHeaderField: "User-Agent")
		
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
	
	func getVersion(for mod: Mod, _ loader: String, _ version: String) async throws -> [Version] {
		try await getVersion(for: mod.id, loader, version)
	}
}
