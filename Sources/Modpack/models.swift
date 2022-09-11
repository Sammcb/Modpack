import Foundation

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
		let versionId: String?
		let projectId: String?
		let dependencyType: String
		
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
	
	enum CodingKeys: String, CodingKey {
		case versionNumber = "version_number"
		case changelog
		case dependencies
		case files
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
