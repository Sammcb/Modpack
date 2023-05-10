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
		
		private typealias UpdateReport = (state: State, checked: [String])
		
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
				
				guard answer.lowercased() == "y" else {
					continue
				}
				
				hashes.insert(file.hashes.sha512)
			}
			
			return State.ProjectState.InstalledVersion(versionId: version.id, fileHashes: hashes)
		}
		
		private func updateDependencies(for projectId: String, _ config: Config, _ state: State, _ checked: [String]) async throws -> UpdateReport {
			guard let versionId = state.projects[projectId]?.installed?.versionId else {
				return UpdateReport(state, checked)
			}
			
			var state = state
			var checked = checked
			let currentVersion = try await getVersion(for: versionId)
			
			for projectDependency in currentVersion.dependencies?.filter({ $0.dependencyType == .required }) ?? [] {
				guard let projectId = try await id(for: projectDependency) else {
					continue
				}
				
				let updateReport = try await update(projectId, config.loaders, config, state, checked, dependency: true)
				state = updateReport.state
				checked = updateReport.checked
			}
			
			return UpdateReport(state, checked)
		}
		
		private func update(_ configProjectId: String, _ loaders: [String], _ config: Config, _ state: State, _ checked: [String], dependency: Bool = false) async throws -> UpdateReport {
			let dependencyLogModifier = dependency ? " dependency" : ""
			
			var checked = checked
			
			// Skip if already checked
			if checked.contains(configProjectId) {
				return UpdateReport(state, checked)
			}
			
			let project = try await getProject(for: configProjectId)
			
			checked.append(project.id)
			
			// Skip if ignored
			if config.ignore.contains(project.id) {
				logger.debug("\tIgnoring\(dependencyLogModifier) \(project.title)...")
				return UpdateReport(state, checked)
			}
			
			logger.info("Checking\(dependencyLogModifier) \(project.title)...")

			var projectState = state.projects[project.id] ?? State.ProjectState()
			
			let versions = try await getVersions(for: project, loaders: loaders, mcVersions: config.versions).filter({ !projectState.skipped.contains($0.id) })
			
			// Skip if no versions match criteria
			guard let latestVersion = versions.first else {
				return UpdateReport(state, checked)
			}
			
			// Check if latest version already installed
			if let installedVersion = projectState.installed, installedVersion.versionId == latestVersion.id {
				let fileHashes = Set(latestVersion.files.map({ $0.hashes.sha512 }))
				
				// Check if files have changed
				if installedVersion.fileHashes.isSubset(of: fileHashes) {
					logger.debug("\tLastest version already exists...")
					return try await updateDependencies(for: project.id, config, state, checked)
				}
				
				logger.warning("\tFiles for \(latestVersion.versionNumber) have changed. Clearing installed version...")
				projectState.installed = nil
			}
			
			logger.info("New versions are available!")
			
			// Print changelogs
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
					skipVersions = []
					break
				}
				
				if answer.lowercased() == "s" {
					logger.info("Skipping update of\(dependencyLogModifier) \(project.title) [\(version.versionNumber)]")
					skipVersions.append(version.id)
					continue
				}
			}
			
			projectState.skipped.append(contentsOf: skipVersions)
			
			var state = state
			state.projects[project.id] = projectState

			return try await updateDependencies(for: project.id, config, state, checked)
		}
		
		mutating func run() async throws {
			logger.logLevel = verbose ? .trace : .info
			
			let configData = try Data(contentsOf: ApiConfig.configFileURL)
			let config = try ApiConfig.json5Decoder.decode(Config.self, from: configData)
			
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
			
			var checked: [String] = []
			
			for projectType in ProjectType.allCases {
				logger.info("Checking \(projectType.rawValue)s for \(versionsString)...")
				let projects = projects(for: projectType, config)
				let loaders = loaders(for: projectType, config)
				for project in projects {
					let updateReport = try await update(project, loaders, config, state, checked)
					checked = updateReport.checked
					state = updateReport.state
				}
				logger.info("")
			}
			
			// Remove projects that were not checked or are ignored
			state.projects = state.projects.filter({ checked.contains($0.key) && !config.ignore.contains($0.key) })

			let encoder = JSONEncoder()
			encoder.outputFormatting = .prettyPrinted
			let stateData = try encoder.encode(state)
			try stateData.write(to: ApiConfig.lockFileURL)
			
			try await install(from: state, config)
		}
	}
}
