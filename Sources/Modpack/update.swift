import Foundation
import ArgumentParser

extension Modpack {
	struct Update: AsyncParsableCommand, ApiActor {
		static var configuration = CommandConfiguration(abstract: "Update and install modpack.")
		
		@Flag(name: [.customShort("c"), .long], help: "Show changelogs for new versions.")
		var showChangelog = false
		
		@Flag(name: .shortAndLong, help: "Print trace and debug information.")
		var verbose = false
		
		func validate() throws {
			guard FileManager.default.fileExists(atPath: ApiConfig.configFileURL.path()) else {
				throw ValidationError("'\(ApiConfig.configFileURL.lastPathComponent)' file does not exist.")
			}
		}
		
		private func install(_ version: Version) throws -> State.ProjectState.InstalledVersion? {
			guard version.files.count > 1 else {
				guard let file = version.files.first else {
					logger.warning("\tNo files exist for this version...")
					return nil
				}
				
				return State.ProjectState.InstalledVersion(versionId: version.id, fileHashes: [file.hashes.sha512])
			}
			
			var hashes: Set<String> = []
			
			logger.info("\tVersion contains multiple files...")
			
			for file in version.files.sorted(by: { $0.primary && !$1.primary }) {
				let primaryLogModifier = file.primary ? " [Primary]" : ""
				logger.info("\tInstall \(file.filename)\(primaryLogModifier)? [(y)es/(N)o]")
				
				guard let answer = readLine() else {
					throw ModpackError.input
				}
				
				if answer.lowercased() == "y" {
					hashes.insert(file.hashes.sha512)
				}
			}
			
			return State.ProjectState.InstalledVersion(versionId: version.id, fileHashes: hashes)
		}
		
		private func updateDependencies(for projectId: String, _ projectState: State.ProjectState, _ config: Config, _ state: State, _ checked: inout [String]) async throws -> State {
			var updatedStateProjects = [projectId: projectState]
			
			guard let installedVersion = projectState.installed else {
				return State(projects: updatedStateProjects)
			}
			
			let currentVersion = try await getVersion(for: installedVersion.versionId)
			
			for modDependency in currentVersion.dependencies?.filter({ $0.dependencyType == .required }) ?? [] {
				guard let projectId = try await id(for: modDependency) else {
					continue
				}
				
				let dependencyMod = Config.Project(id: projectId)
				let updatedStates = State(projects: state.projects.merging(updatedStateProjects, uniquingKeysWith: { (_, new ) in new }))
				let dependencyStates = try await update(dependencyMod, config.loaders, config, updatedStates, &checked, dependency: true)
				
				updatedStateProjects.merge(dependencyStates.projects, uniquingKeysWith: { (_, new) in new })
			}
			
			return State(projects: updatedStateProjects)
		}
		
		private func update(_ configProject: Config.Project, _ loaders: [String], _ config: Config, _ state: State, _ checked: inout [String], dependency: Bool = false) async throws -> State {
			let dependencyLogModifier = dependency ? " dependency" : ""
			
			var projectState = state.projects.filter({ $0.key == configProject.id }).values.first ?? State.ProjectState()
			
			if checked.contains(configProject.id) {
				return try await updateDependencies(for: configProject.id, projectState, config, state, &checked)
			}
			
			let project = try await getProject(for: configProject.id)
			
			checked.append(project.id)
			
			if config.ignore.contains(where: { $0.id == project.id }) {
				logger.debug("\tIgnoring\(dependencyLogModifier) \(project.title)...")
				return State()
			}
			
			logger.info("Fetching versions for\(dependencyLogModifier) \(project.title)...")
			
			let versions = try await getVersions(for: project, loaders: loaders, mcVersions: config.versions).filter({ !projectState.skipped.contains($0.id) })
			
			guard let latestVersion = versions.first else {
				return try await updateDependencies(for: project.id, projectState, config, state, &checked)
			}
			
			if let installedVersion = projectState.installed, installedVersion.versionId == latestVersion.id {
				let fileHashes = Set(latestVersion.files.map({ $0.hashes.sha512 }))
				if installedVersion.fileHashes.isSubset(of: fileHashes) {
					logger.debug("\tLastest version already exists...")
					return try await updateDependencies(for: project.id, projectState, config, state, &checked)
				}
				
				logger.warning("\tFiles for \(latestVersion.versionNumber) have changed. Clearing installed version...")
				projectState.installed = nil
			}
			
			logger.info("New versions are available!")
			
			for version in versions {
				if version.id == projectState.installed?.versionId {
					break
				}
				
				if showChangelog, let changelog = version.changelog {
					logger.info("Changlog for [\(version.versionNumber)]:")
					logger.info("\(changelog.trimmingCharacters(in: .whitespacesAndNewlines))\n")
				}
			}
			
			var skipVersions: [String] = []
			for version in versions {
				logger.info("Update\(dependencyLogModifier) \(project.title) to [\(version.versionNumber)]? [(y)es, (s)kip, (N)o]")
				
				guard let answer = readLine() else {
					throw ModpackError.input
				}
				
				if answer.lowercased() == "y" {
					guard let installedVersion = try install(version) else {
						continue
					}
					
					projectState.installed = installedVersion
					projectState.skipped = skipVersions
					break
				}
				
				if answer.lowercased() == "s" {
					logger.info("Skipping update of\(dependencyLogModifier) \(project.title) [\(version.versionNumber)]")
					skipVersions.append(version.id)
					continue
				}
			}
			
			skipVersions.removeAll(where: { projectState.skipped.contains($0) })
			projectState.skipped.append(contentsOf: skipVersions)

			return try await updateDependencies(for: project.id, projectState, config, state, &checked)
		}
		
		mutating func run() async throws {
			logger.logLevel = verbose ? .trace : .info
			
			let configData = try Data(contentsOf: ApiConfig.configFileURL)
			let config = try JSONDecoder().decode(Config.self, from: configData)
			
			let versionsString = "[\(config.versions.joined(separator: ", "))]"
			logger.info("Checking projects for updates for Minecraft version(s) \(versionsString)\n")
			
			for url in config.directories.values {
				if FileManager.default.fileExists(atPath: url.path()) {
					continue
				}
				
				logger.debug("'\(url.lastPathComponent)' directory does not exist, creating...")
				try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
			}
			
			var state = State()
			if FileManager.default.fileExists(atPath: ApiConfig.lockFileURL.path()) {
				let stateData = try Data(contentsOf: ApiConfig.lockFileURL)

				if !stateData.isEmpty {
					state = try JSONDecoder().decode(State.self, from: stateData)
				}
			} else {
				logger.debug("'\(ApiConfig.lockFileURL.lastPathComponent)' file does not exist, creating...")
				FileManager.default.createFile(atPath: ApiConfig.lockFileURL.path(), contents: nil)
			}
			
			var checkedProjects: [String] = []
			var newState = State()
			
			for projectType in ProjectType.allCases {
				logger.info("Checking \(projectType.rawValue)s for \(versionsString)...")
				let projects = projects(for: projectType, config)
				let loaders = loaders(for: projectType, config)
				for project in projects {
					let updatedState = try await update(project, loaders, config, state, &checkedProjects)
					newState.projects.merge(updatedState.projects, uniquingKeysWith: { (_, new) in new })
					state.projects.merge(updatedState.projects, uniquingKeysWith: { (_, new) in new })
				}
				logger.info("")
			}

			let encoder = JSONEncoder()
			encoder.outputFormatting = .prettyPrinted
			let stateData = try encoder.encode(newState)
			try stateData.write(to: ApiConfig.lockFileURL)
			
			try await install(from: newState, config)
		}
	}
}
