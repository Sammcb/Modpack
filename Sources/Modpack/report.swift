import Foundation
import ArgumentParser

extension Modpack {
	struct Report: AsyncParsableCommand, ApiActor {
		private struct ProjectReport {
			let id: String
			let name: String
			let valid: Bool
			let datapack: Bool
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
				return [ProjectReport(id: configProject.id, name: "", valid: false, datapack: false, dependency: false, ignore: true)]
			}
			
			let dependencyLogModifier = dependency ? " dependency" : ""
			let isDatapack = loaders.contains("datapack")
			
			let project = try await getProject(for: configProject.id)
			
			let versions = try await getVersions(for: project, loaders: loaders, mcVersions: mcVersions, dependencyLogModifier: dependencyLogModifier)
			
			guard let validVersion = versions.first else {
				return [ProjectReport(id: project.id, name: project.title, valid: false, datapack: isDatapack, dependency: dependency)]
			}
			
			let projectReport = ProjectReport(id: project.id, name: project.title, valid: true, datapack: isDatapack, dependency: dependency)
			var projectReports = [projectReport]
			for projectDependency in validVersion.dependencies?.filter({ $0.dependencyType == .required }) ?? [] {
				guard let projectId = projectDependency.projectId else {
					continue
				}
				
				let dependencyProject = Config.Project(name: "", id: projectId)
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
			
			projectReports.removeAll(where: { $0.ignore })
			let modReadyCount = projectReports.filter({ $0.valid && !$0.datapack }).count
			logger.info("Mods (total)")
			logger.info("[\(modReadyCount)/\(projectReports.filter({ !$0.datapack }).count)] support \(versionsString)\n")
			
			let invalidMods = projectReports.filter({ !$0.valid && !$0.datapack }).map({ $0.name })
			if !invalidMods.isEmpty {
				logger.notice("Mods not compatible:\n\(invalidMods.joined(separator: "\n"))\n")
			}
			
			let dependencyReadyCount = projectReports.filter({ $0.valid && $0.dependency }).count
			let dependencyCount = projectReports.filter({ $0.dependency }).count
			logger.info("Mods (dependencies)")
			logger.info("[\(dependencyReadyCount)/\(dependencyCount)] support \(versionsString)\n")
			
			let datapackReadyCount = projectReports.filter({$0.valid && $0.datapack }).count
			logger.info("Datapacks")
			logger.info("[\(datapackReadyCount)/\(projectReports.filter({ $0.datapack }).count)] support \(versionsString)\n")
			
			let invalidDatapacks = projectReports.filter({ !$0.valid && $0.datapack }).map({ $0.name })
			if !invalidDatapacks.isEmpty {
				logger.notice("Datapacks not compatible:\n\(invalidDatapacks.joined(separator: "\n"))\n")
			}
		}
	}
}
