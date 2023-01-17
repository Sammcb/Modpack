import Foundation

struct Config: Codable {
	struct Project: Codable {
		let id: String
	}
	
	let loaders: [String]
	let versions: [String]
	private let modsDirectory: String
	let mods: [Config.Project]
	let ignore: [Config.Project]
	private let datapacksDirectory: String
	let datapacks: [Config.Project]
	private let resourcepacksDirectory: String
	let resourcepacks: [Config.Project]
	
	var directories: [ProjectType: URL] {
		[
			.mod: ApiConfig.baseURL.appending(path: modsDirectory, directoryHint: .isDirectory),
			.datapack: ApiConfig.baseURL.appending(path: datapacksDirectory, directoryHint: .isDirectory),
			.resourcepack: ApiConfig.baseURL.appending(path: resourcepacksDirectory, directoryHint: .isDirectory)
		]
	}
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
	case directoryMissing
	case api(_ error: String)
}

enum ProjectType: String, Identifiable, CaseIterable {
	case mod
	case datapack
	case resourcepack
	
	var id: String { rawValue }
}
