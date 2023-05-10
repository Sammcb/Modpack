import Foundation

struct Config: Codable {
	let loaders: [String]
	let versions: [String]
	private let modsDirectory: String
	let mods: [String]
	let ignore: [String]
	private let datapacksDirectory: String
	let datapacks: [String]
	private let resourcepacksDirectory: String
	let resourcepacks: [String]
	let shaderLoaders: [String]
	private let shaderpacksDirectory: String
	let shaderpacks: [String]
	let manual: [String]
	
	var directories: [ProjectType: URL] {
		[
			.mod: ApiConfig.baseURL.appending(path: modsDirectory, directoryHint: .isDirectory),
			.datapack: ApiConfig.baseURL.appending(path: datapacksDirectory, directoryHint: .isDirectory),
			.resourcepack: ApiConfig.baseURL.appending(path: resourcepacksDirectory, directoryHint: .isDirectory),
			.shaderpack: ApiConfig.baseURL.appending(path: shaderpacksDirectory, directoryHint: .isDirectory)
		]
	}
}

struct State: Codable {
	struct ProjectState: Codable {
		struct InstalledVersion: Codable {
			let versionId: String
			let fileHashes: Set<String>
		}
		
		var skipped: [String] = []
		var installed: InstalledVersion?
	}
	
	var projects: [String: ProjectState] = [:]
}

struct Project: Codable {
	let title: String
	let id: String
}

struct Version: Codable {
	struct Dependency: Codable {
		enum DependencyType: String, Codable {
			case required
			case optional
			case incompatible
			case embedded
		}
		
		let versionId: String?
		let projectId: String?
		let dependencyType: DependencyType
		
		enum CodingKeys: String, CodingKey {
			case versionId = "version_id"
			case projectId = "project_id"
			case dependencyType = "dependency_type"
		}
	}
	
	struct File: Codable {
		struct Hashes: Codable {
			let sha512: String
		}
		
		let url: String
		let filename: String
		let primary: Bool
		let hashes: Hashes
	}
	
	let id: String
	let versionNumber: String
	let projectId: String
	let changelog: String?
	let dependencies: [Dependency]?
	let files: [File]
	let loaders: [String]
	let gameVersions: [String]
	let datePublished: Date
	
	enum CodingKeys: String, CodingKey {
		case versionNumber = "version_number"
		case projectId = "project_id"
		case gameVersions = "game_versions"
		case datePublished = "date_published"
		case id
		case changelog
		case dependencies
		case files
		case loaders
	}
}

struct ResponseError: Codable {
	let error: String
	let description: String
}

enum ModpackError: Error {
	case responseHeaders
	case requestStatus
	case input
	case api(_ error: String)
}

enum ProjectType: String, Identifiable, CaseIterable {
	case mod
	case datapack
	case resourcepack
	case shaderpack
	
	var id: String { rawValue }
}
