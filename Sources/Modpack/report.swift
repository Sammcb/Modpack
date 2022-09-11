import Foundation
import ArgumentParser

extension Modpack {
	struct Report: AsyncParsableCommand, ApiActor {
		struct ModReport {
			let id: String
			let name: String
			let valid: Bool
			let dependency: Bool
		}
		
		static var configuration = CommandConfiguration(abstract: "Check modpack compatibility for a specified Minecraft version.")
		
		@Argument(help: "Mod list json file.")
		var configPath: String
		
		@Argument(help: "Minecraft version to check compatibility with.")
		var version: String
		
		func validate() throws {
			let configFileURL = URL(fileURLWithPath: configPath)
			
			guard configFileURL.pathExtension == "json" else {
				throw ValidationError("Mod list must be a json file.")
			}
			
			guard FileManager.default.fileExists(atPath: configFileURL.path) else {
				throw ValidationError("Mod list file does not exist.")
			}
		}
		
		private func report(_ mod: Mod, _ loader: String, _ version: String, checkedMods: [String], dependency: Bool = false) async throws -> [ModReport] {
			if checkedMods.contains(mod.id) {
				return []
			}
			
			let project = try await getProject(for: mod.id)
			let versions = try await getVersion(for: mod, loader, version)
			
			guard let validVersion = versions.first else {
				return [ModReport(id: mod.id, name: project.title, valid: false, dependency: dependency)]
			}
			
			var modReport = [ModReport(id: mod.id, name: project.title, valid: true, dependency: dependency)]
			for modDependency in validVersion.dependencies ?? [] {
				guard let projectId = modDependency.projectId else {
					continue
				}
				
				let dependencyMod = Mod(name: "dependency", id: projectId, url: nil)
				let dependencyReports = try await report(dependencyMod, loader, version, checkedMods: checkedMods + [mod.id], dependency: true)
				
				modReport.append(contentsOf: dependencyReports)
			}
			
			return modReport
		}
		
		mutating func run() async throws {
			logger.logLevel = .info
			
			let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			logger.info("Generating report for Minecraft version \(version)...")
			
			var modReports: [ModReport] = []
			for mod in config.mods where mod.url == nil {
				let modReport = try await report(mod, config.loader, version, checkedMods: modReports.map({ $0.id }))
				modReports.append(contentsOf: modReport)
			}
			
			let readyCount = modReports.filter({ $0.valid }).count
			logger.info("Total")
			logger.info("[\(readyCount)/\(modReports.count)] support \(version)\n")
			logger.notice("Mods not compatible:\n\(modReports.filter({ !$0.valid }).map({ $0.name }).joined(separator: "\n"))\n")
			let dependencyReadyCount = modReports.filter({ $0.valid && $0.dependency }).count
			let dependencyCount = modReports.filter({ $0.dependency }).count
			logger.info("Dependency")
			logger.info("[\(dependencyReadyCount)/\(dependencyCount)] support \(version)\n")
			logger.warning("CurseForge mods need to be checked manually.")
		}
	}
}
