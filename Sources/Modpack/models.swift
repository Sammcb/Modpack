import Foundation

struct Mod: Codable {
	let name: String
	let id: String
	let url: String?
}

struct Config: Codable {
	let loaders: [String]
	let versions: [String]
	let mods: [Mod]
	let ignore: [Mod]
}

struct Project: Codable {
	let title: String
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
		let url: String
		let filename: String
		let primary: Bool
	}
	
	let versionNumber: String
	let changelog: String?
	let dependencies: [Dependency]?
	let files: [File]
	let loaders: [String]
	let gameVersions: [String]
	let datePublished: Date
	
	enum CodingKeys: String, CodingKey {
		case versionNumber = "version_number"
		case gameVersions = "game_versions"
		case datePublished = "date_published"
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
	case api(_ error: String)
}
