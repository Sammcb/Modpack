import Foundation
import ArgumentParser

extension Modpack {
	struct Report: AsyncParsableCommand, ApiActor {
		private struct ProjectReport {
			let id: String
			let name: String
			let valid: Bool
			let projectType: ProjectType
			let dependency: Bool
			var ignore: Bool = false
		}
		
		static var configuration = CommandConfiguration(abstract: "Check modpack compatibility for a specified Minecraft version.")
		
		@Argument(help: "Mod list json file.")
		var configPath: String
		
		@Argument(help: "Minecraft version to check compatibility with.")
		var versions: [String]
		
		func validate() throws {
			let configFileURL = URL(fileURLWithPath: configPath)
			
			guard configFileURL.pathExtension == "json" else {
				throw ValidationError("Mod list must be a json file.")
			}
			
			guard FileManager.default.fileExists(atPath: configPath) else {
				throw ValidationError("Mod list file does not exist.")
			}
		}
		
		private func report(_ configProject: Config.Project, _ loaders: [String], _ mcVersions: [String], _ ignoreProjects: [Config.Project], checkedMods: [ProjectReport], dependency: Bool = false) async throws -> [ProjectReport] {
			if checkedMods.contains(where: { $0.id == configProject.id }) {
				return []
			}
			
			if ignoreProjects.contains(where: { $0.id == configProject.id }) {
				return [ProjectReport(id: configProject.id, name: "", valid: false, projectType: .mod, dependency: false, ignore: true)]
			}
			
			let project = try await getProject(for: configProject.id)
			
			let versions = try await getVersions(for: project, loaders: loaders, mcVersions: mcVersions)
			
			let type = projectType(with: loaders)
			
			guard let validVersion = versions.first else {
				return [ProjectReport(id: project.id, name: project.title, valid: false, projectType: type, dependency: dependency)]
			}
			
			let projectReport = ProjectReport(id: project.id, name: project.title, valid: true, projectType: type, dependency: dependency)
			var projectReports = [projectReport]
			for projectDependency in validVersion.dependencies?.filter({ $0.dependencyType == .required }) ?? [] {
				guard let projectId = projectDependency.projectId else {
					continue
				}
				
				let dependencyProject = Config.Project(id: projectId)
				let dependencyReports = try await report(dependencyProject, loaders, mcVersions, ignoreProjects, checkedMods: checkedMods + [projectReport], dependency: true)
				
				projectReports.append(contentsOf: dependencyReports)
			}
			
			return projectReports
		}
		
		mutating func run() async throws {
			logger.logLevel = .info
			
			let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			let versionsString = "[\(versions.joined(separator: ", "))]"
			
			logger.info("Generating report for Minecraft version(s) \(versionsString)...")
			
			var projectReports: [ProjectReport] = []
			for mod in config.mods {
				let modReport = try await report(mod, config.loaders, versions, config.ignore, checkedMods: projectReports)
				projectReports.append(contentsOf: modReport)
			}
			
			for datapack in config.datapacks {
				let datapackReport = try await report(datapack, ["datapack"], versions, config.ignore, checkedMods: projectReports)
				projectReports.append(contentsOf: datapackReport)
			}
			
			for resourcepack in config.resourcepacks {
				let resourcepackReport = try await report(resourcepack, ["minecraft"], versions, config.ignore, checkedMods: projectReports)
				projectReports.append(contentsOf: resourcepackReport)
			}
			
			projectReports.removeAll(where: { $0.ignore })
			
			for type in ProjectType.allCases {
				let filteredReports = projectReports.filter({ $0.projectType == type })
				
				if filteredReports.isEmpty {
					continue
				}
				
				let readyCount = filteredReports.filter({ $0.valid }).count
				let typeString = "\(type.rawValue.capitalized)s"
				logger.info("\(typeString) (total)")
				logger.info("[\(readyCount)/\(filteredReports.count)] support \(versionsString)\n")
				
				let invalidProjects = filteredReports.filter({ !$0.valid }).map({ $0.name })
				if !invalidProjects.isEmpty {
					logger.notice("\(typeString) not compatible:\n\(invalidProjects.joined(separator: "\n"))\n")
				}
				
				let dependencyReports = filteredReports.filter({ $0.dependency })
				let dependencyReadyCount = dependencyReports.filter({ $0.valid }).count
				let dependencyCount = dependencyReports.count
				
				guard dependencyCount > 0 else {
					continue
				}
				
				logger.info("\(typeString) (dependencies)")
				logger.info("[\(dependencyReadyCount)/\(dependencyCount)] support \(versionsString)\n")
			}
			
			let readyCount = projectReports.filter({ $0.valid }).count
			
			logger.info("Total")
			logger.info("[\(readyCount)/\(projectReports.count)] support \(versionsString)")
		}
	}
}
