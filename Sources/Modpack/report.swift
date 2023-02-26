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
		
		@Argument(help: "Minecraft version to check compatibility with.")
		var versions: [String]
		
		func validate() throws {
			guard FileManager.default.fileExists(atPath: ApiConfig.configFileURL.path()) else {
				throw ValidationError("'\(ApiConfig.configFileURL.lastPathComponent)' file does not exist.")
			}
		}
		
		private func report(_ configProject: Config.Project, _ type: ProjectType, _ loaders: [String], _ config: Config, checkedMods: [ProjectReport], dependency: Bool = false) async throws -> [ProjectReport] {
			if checkedMods.contains(where: { $0.id == configProject.id }) {
				return []
			}
			
			if config.ignore.contains(where: { $0.id == configProject.id }) {
				return [ProjectReport(id: configProject.id, name: "", valid: false, projectType: .mod, dependency: false, ignore: true)]
			}
			
			let project = try await getProject(for: configProject.id)
			
			let projectVersions = try await getVersions(for: project, loaders: loaders, mcVersions: versions)
			
			guard let validVersion = projectVersions.first else {
				return [ProjectReport(id: project.id, name: project.title, valid: false, projectType: type, dependency: dependency)]
			}
			
			let projectReport = ProjectReport(id: project.id, name: project.title, valid: true, projectType: type, dependency: dependency)
			var projectReports = [projectReport]
			for projectDependency in validVersion.dependencies?.filter({ $0.dependencyType == .required }) ?? [] {
				guard let projectId = try await id(for: projectDependency) else {
					continue
				}
				
				let dependencyProject = Config.Project(id: projectId)
				let dependencyReports = try await report(dependencyProject, type, loaders, config, checkedMods: checkedMods + [projectReport], dependency: true)
				
				projectReports.append(contentsOf: dependencyReports)
			}
			
			return projectReports
		}
		
		mutating func run() async throws {
			logger.logLevel = .info
			
			let configData = try Data(contentsOf: ApiConfig.configFileURL)
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			let versionsString = "[\(versions.joined(separator: ", "))]"
			
			logger.info("Generating report for Minecraft version(s) \(versionsString)...")
			
			var projectReports: [ProjectReport] = []
			
			for projectType in ProjectType.allCases {
				let projects = projects(for: projectType, config)
				let loaders = loaders(for: projectType, config)
				for project in projects {
					let projectReport = try await report(project, projectType, loaders, config, checkedMods: projectReports)
					projectReports.append(contentsOf: projectReport)
				}
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
