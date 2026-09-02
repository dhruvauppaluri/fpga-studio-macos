import AppKit
import Combine
import CryptoKit
import FPGAStudioCore
import Foundation

struct SourceDocument: Identifiable, Hashable {
    let id: String
    let url: URL
    var language: HDLLanguage
    var text: String
    var isDirty = false

    var title: String { url.lastPathComponent }
}

@MainActor
final class WorkspaceController: ObservableObject {
    @Published var project: FPGAProject?
    @Published var rootURL: URL?
    @Published var documents: [SourceDocument] = []
    @Published var selectedDocumentID: String?
    @Published var selectedTestID: String?
    @Published var selectedBottomTab = "Issues"
    @Published var searchText = ""
    @Published var log = ""
    @Published var diagnostics: [Diagnostic] = []
    @Published var artifacts: [BuildArtifact] = []
    @Published var waveform: VCDDocument?
    @Published var stage: BuildStage = .idle
    @Published var isRunning = false
    @Published var boardConnected = false
    @Published var showingNewProject = false
    @Published var showingFlashConfirmation = false
    @Published var showingSimulationTrust = false
    @Published var showingLearnCenter = false
    @Published var showingWelcomeTour = false
    @Published var showingInspector = true
    @Published var toolHealth: [ToolHealth] = []
    @Published var lastError: String?
    @Published private(set) var constraintsRevision = 0
    @Published private(set) var flashCandidate: ProgrammingArtifact?
    @Published private(set) var lastValidationSucceeded = false
    @Published private(set) var lastBuildSucceeded = false
    @Published private(set) var lastProgrammedSRAM = false
    @Published private(set) var lastProgrammedSRAMSHA256: String?

    let board: BoardProfile
    private let pipeline = BuildPipeline()
    private let toolchain = ToolchainManager()
    private var operation: Task<Void, Never>?
    private var powerActivity: NSObjectProtocol?
    private var lastBuildFingerprint: String?
    private let documentSaver = DocumentSaveCoordinator()
    private var activeEditorDocumentID: String?
    private var activeEditorSnapshot: (@MainActor () -> String)?
    private var autosaveTask: Task<Void, Never>?
    private var editGenerations: [String: Int] = [:]
    private var saveSessionIDs: [String: String] = [:]

    init() {
        do { board = try BundledResources.boardProfile() }
        catch { fatalError("Bundled C5G board profile is invalid: \(error)") }
        refreshToolchain()
    }

    var selectedDocument: SourceDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    var canRun: Bool { project != nil && !isRunning && !(project?.isReadOnly ?? true) }
    var canSimulate: Bool { canRun && !(project?.tests.isEmpty ?? true) }
    var canCancel: Bool { isRunning && stage != .programmingFlash }
    var canProgramSRAM: Bool { canRun && lastBuildSucceeded && boardConnected && board.isSRAMProgrammingValidated }
    var canProgramFlash: Bool { canRun && board.isFlashProgrammingValidated && lastProgrammedSRAMSHA256 != nil }
    var learningProgress: LearningProgress {
        .init(
            validated: lastValidationSucceeded,
            simulated: waveform != nil,
            built: lastBuildSucceeded,
            boardConnected: boardConnected,
            programmedSRAM: lastProgrammedSRAM
        )
    }
    var buildToolsReady: Bool {
        let available = Set(toolHealth.filter(\.isAvailable).map(\.executable))
        return available.contains("yosys") && available.contains("nextpnr-mistral")
    }

    var recentProjects: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(ProjectStore.manifestName).path) }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open FPGA Project"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url) }
    }

    func openProject(at url: URL) {
        Task {
            guard await flushPendingEdits() else { return }
            openProjectNow(at: url)
        }
    }

    private func openProjectNow(at url: URL) {
        do {
            let loaded = try ProjectStore.load(from: url)
            project = loaded
            rootURL = url
            selectedTestID = loaded.tests.first?.id
            documents = []
            selectedDocumentID = nil
            diagnostics = ProjectValidator.validate(project: loaded, root: url, board: board)
            lastValidationSucceeded = false
            lastBuildSucceeded = false
            lastProgrammedSRAM = false
            lastProgrammedSRAMSHA256 = nil
            lastBuildFingerprint = nil
            boardConnected = false
            waveform = nil
            editGenerations = [:]
            saveSessionIDs = [:]
            remember(url)
            if let first = loaded.sources.first { loadSource(first) }
        } catch { lastError = error.localizedDescription }
    }

    func closeProject() {
        Task {
            guard await flushPendingEdits() else { return }
            closeProjectNow()
        }
    }

    private func closeProjectNow() {
        project = nil
        rootURL = nil
        documents = []
        selectedDocumentID = nil
        waveform = nil
        log = ""
        lastValidationSucceeded = false
        lastBuildSucceeded = false
        lastProgrammedSRAM = false
        lastProgrammedSRAMSHA256 = nil
        lastBuildFingerprint = nil
        flashCandidate = nil
        boardConnected = false
        editGenerations = [:]
        saveSessionIDs = [:]
    }

    func createProject(template: ProjectTemplate, language: HDLLanguage, name: String, parent: URL) {
        Task {
            guard await flushPendingEdits() else { return }
            do {
                let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !safeName.isEmpty, !safeName.contains("/") else { throw FPGAStudioError.invalidProject("Choose a simple project name.") }
                let destination = parent.appendingPathComponent(safeName, isDirectory: true)
                _ = try ProjectTemplateFactory.create(template, language: language, name: safeName, at: destination)
                showingNewProject = false
                openProjectNow(at: destination)
            } catch { lastError = error.localizedDescription }
        }
    }

    func openSource(_ source: ProjectSource) {
        Task {
            guard await flushPendingEdits() else { return }
            loadSource(source)
        }
    }

    private func loadSource(_ source: ProjectSource) {
        guard let rootURL else { return }
        do {
            let url = try ProjectStore.resolve(source.path, under: rootURL)
            if !documents.contains(where: { $0.id == source.path }) {
                documents.append(.init(id: source.path, url: url, language: source.language, text: try String(contentsOf: url, encoding: .utf8)))
                editGenerations[source.path] = 0
                saveSessionIDs[source.path] = "\(source.path)#\(UUID().uuidString)"
            }
            selectedDocumentID = source.path
        } catch { lastError = error.localizedDescription }
    }

    func selectDocument(_ documentID: String) {
        guard documentID != selectedDocumentID else { return }
        Task {
            guard await flushPendingEdits() else { return }
            selectedDocumentID = documentID
        }
    }

    func registerEditorBuffer(
        documentID: String,
        snapshot: @escaping @MainActor () -> String
    ) {
        activeEditorDocumentID = documentID
        activeEditorSnapshot = snapshot
    }

    func unregisterEditorBuffer(documentID: String) {
        guard activeEditorDocumentID == documentID else { return }
        activeEditorDocumentID = nil
        activeEditorSnapshot = nil
    }

    func editorDidChange(documentID: String) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        editGenerations[documentID, default: 0] += 1
        if !documents[index].isDirty {
            documents[index].isDirty = true
            invalidateGeneratedResults()
        }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.activeEditorDocumentID == documentID else { return }
            _ = await self.commitActiveEditor()
        }
    }

    func save() {
        Task { _ = await flushPendingEdits() }
    }

    @discardableResult
    func flushPendingEdits() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil

        if let activeEditorDocumentID {
            var attempts = 0
            while documents.first(where: { $0.id == activeEditorDocumentID })?.isDirty == true,
                  attempts < 3 {
                guard await commitActiveEditor() else { return false }
                attempts += 1
            }
            guard documents.first(where: { $0.id == activeEditorDocumentID })?.isDirty != true else {
                return false
            }
        }

        for document in documents where document.isDirty && document.id != activeEditorDocumentID {
            let generation = editGenerations[document.id, default: 0]
            if !(await persist(documentID: document.id, text: document.text, generation: generation)) {
                return false
            }
        }
        return true
    }

    private func commitActiveEditor() async -> Bool {
        guard let documentID = activeEditorDocumentID,
              let snapshot = activeEditorSnapshot,
              let index = documents.firstIndex(where: { $0.id == documentID }),
              documents[index].isDirty else { return true }
        let text = snapshot()
        documents[index].text = text
        let generation = editGenerations[documentID, default: 0]
        return await persist(documentID: documentID, text: text, generation: generation)
    }

    private func persist(documentID: String, text: String, generation: Int) async -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return true }
        let url = documents[index].url
        do {
            _ = try await documentSaver.write(
                documentID: saveSessionIDs[documentID] ?? documentID,
                revision: generation,
                text: text,
                to: url
            )
            if editGenerations[documentID, default: 0] == generation,
               let currentIndex = documents.firstIndex(where: { $0.id == documentID }) {
                documents[currentIndex].isDirty = false
            }
            return true
        } catch {
            if let currentIndex = documents.firstIndex(where: { $0.id == documentID }) {
                documents[currentIndex].isDirty = true
            }
            lastError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    func simulateSelectedTest() {
        guard isCurrentProjectTrusted else {
            showingSimulationTrust = true
            return
        }
        runSelectedTest()
    }

    func trustProjectAndSimulate() {
        guard let trustIdentifier else { return }
        var trusted = Set(UserDefaults.standard.stringArray(forKey: "trustedSimulationProjects") ?? [])
        trusted.insert(trustIdentifier)
        UserDefaults.standard.set(Array(trusted), forKey: "trustedSimulationProjects")
        showingSimulationTrust = false
        runSelectedTest()
    }

    private func runSelectedTest() {
        guard let project else { return }
        let test = project.tests.first(where: { $0.id == selectedTestID }) ?? project.tests.first
        guard let test else { return }
        perform(.simulate(test: test))
    }

    func perform(_ action: BuildAction) {
        guard let project, let rootURL, !isRunning else { return }
        if case .programSRAM = action {
            guard lastBuildSucceeded else {
                lastError = "Build the current design before programming the FPGA."
                return
            }
            guard boardConnected else {
                lastError = "Connect and detect the C5G before programming the FPGA."
                return
            }
        }
        isRunning = true
        operation = Task { [weak self] in
            guard let self else { return }
            guard await flushPendingEdits() else {
                finishOperation()
                return
            }
            guard !Task.isCancelled else { finishOperation(); return }
            log = ""
            diagnostics = []
            artifacts = []
            selectedBottomTab = action.isSimulation ? "Simulation" : "Build Log"
            if action.isFlash {
                AppLifecycleDelegate.flashWriteActive = true
                powerActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .userInitiated], reason: "Programming C5G persistent flash")
            }
            let outcome = await pipeline.run(action: action, project: project, root: rootURL, board: board) { stage, message in
                Task { @MainActor [weak self] in
                    self?.stage = stage == .idle ? self?.stage ?? .idle : stage
                    self?.log.append(message)
                }
            }
            guard !Task.isCancelled else { self.finishOperation(); return }
            diagnostics = outcome.diagnostics
            artifacts = outcome.artifacts
            log.append(outcome.log)
            stage = outcome.stage
            if case .detectDevice = action { boardConnected = outcome.succeeded }
            if action.isSimulation,
               let artifact = outcome.artifacts.first(where: { $0.kind.contains("VCD") }),
               let parsed = try? VCDParser.parse(url: URL(fileURLWithPath: artifact.path)) {
                waveform = parsed
                selectedBottomTab = "Waveform"
            }
            if outcome.succeeded {
                switch action {
                case .validate:
                    lastValidationSucceeded = true
                case .simulate:
                    lastValidationSucceeded = true
                case .build:
                    lastValidationSucceeded = true
                    lastBuildSucceeded = true
                    lastBuildFingerprint = try? ProjectFingerprint.compute(project: project, root: rootURL)
                case .detectDevice:
                    boardConnected = true
                case .programSRAM(let artifact):
                    lastProgrammedSRAM = true
                    lastProgrammedSRAMSHA256 = artifact.sha256
                case .programFlash:
                    break
                }
            }
            if !outcome.succeeded {
                selectedBottomTab = "Issues"
                if action.isProgramming { boardConnected = false }
            }
            finishOperation()
        }
    }

    func programSRAM() {
        do {
            perform(.programSRAM(artifact: try makeProgrammingArtifact()))
        } catch { lastError = error.localizedDescription }
    }

    func prepareFlash() {
        guard board.isFlashProgrammingValidated else {
            lastError = "Persistent flash is locked for the C5G. Upstream marks this board's flash path as not tested, and physical acceptance has not been completed. Use Program SRAM instead."
            return
        }
        guard lastBuildSucceeded else {
            lastError = "Build the current design before programming persistent flash."
            return
        }
        guard boardConnected else {
            lastError = "Connect and detect the C5G before programming persistent flash."
            return
        }
        do {
            let artifact = try makeProgrammingArtifact()
            guard lastProgrammedSRAMSHA256 == artifact.sha256 else {
                lastError = "Test this exact bitstream in SRAM successfully before writing persistent flash."
                return
            }
            flashCandidate = artifact
            showingFlashConfirmation = true
        } catch { lastError = error.localizedDescription }
    }

    func confirmFlash() {
        guard let flashCandidate else { lastError = FPGAStudioError.noBitstream.localizedDescription; return }
        guard board.isFlashProgrammingValidated, lastProgrammedSRAMSHA256 == flashCandidate.sha256 else {
            lastError = "Flash authorization expired. Detect the board and test this exact bitstream in SRAM again."
            return
        }
        showingFlashConfirmation = false
        perform(.programFlash(artifact: flashCandidate))
    }

    func cancel() {
        guard canCancel else { return }
        operation?.cancel()
        Task { await pipeline.cancel() }
        finishOperation()
    }

    var latestBitstream: URL? {
        if let artifact = artifacts.last(where: { $0.kind.contains("RBF") }) { return URL(fileURLWithPath: artifact.path) }
        guard let rootURL else { return nil }
        let release = rootURL.appendingPathComponent(".fpga/build/release")
        let entries = (try? FileManager.default.contentsOfDirectory(at: release, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "rbf" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.first
    }

    var bitstreamSHA256: String {
        flashCandidate?.sha256 ?? "Unavailable"
    }

    var constraintAssignments: [PinAssignment] {
        guard let project, let rootURL,
              let url = try? ProjectStore.resolve(project.constraints, under: rootURL),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return QSFParser.parse(text)
    }

    var topPortDirections: [String: PinDirection] {
        guard let project, let rootURL else { return [:] }
        var result: [String: PinDirection] = [:]
        for source in project.sources where !source.isTestbench {
            guard let url = try? ProjectStore.resolve(source.path, under: rootURL),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result.merge(SourcePortExtractor.portDirections(in: text, language: source.language, top: project.top)) { existing, _ in existing }
        }
        return result
    }

    func assign(_ signal: String, to pin: BoardPin) {
        guard let project, let rootURL else { return }
        let current = constraintAssignments
        if let conflict = current.first(where: { $0.packagePin == pin.packagePin && $0.signal != signal }) {
            lastError = "\(pin.packagePin) is already assigned to \(conflict.signal). Choose another pin first."
            return
        }
        let base = signal.split(separator: "[").first.map(String.init) ?? signal
        if let direction = topPortDirections[base], direction != .bidirectional, pin.direction != .bidirectional, direction != pin.direction {
            lastError = "\(signal) is a top-level \(direction.rawValue), but \(pin.signal) is a board \(pin.direction.rawValue)."
            return
        }
        do {
            let url = try ProjectStore.resolve(project.constraints, under: rootURL)
            var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            let escaped = NSRegularExpression.escapedPattern(for: signal)
            let location = try NSRegularExpression(pattern: #"^\s*set_location_assignment\s+PIN_[A-Z0-9]+\s+-to\s+\"?"# + escaped + #"\"?\s*$"#)
            let standard = try NSRegularExpression(pattern: #"^\s*set_instance_assignment\s+-name\s+IO_STANDARD\s+.+?\s+-to\s+\"?"# + escaped + #"\"?\s*$"#, options: .caseInsensitive)
            var locationFound = false
            var standardFound = false
            for index in lines.indices {
                let range = NSRange(lines[index].startIndex..<lines[index].endIndex, in: lines[index])
                if location.firstMatch(in: lines[index], range: range) != nil {
                    lines[index] = "set_location_assignment \(pin.packagePin) -to \(signal)"
                    locationFound = true
                } else if standard.firstMatch(in: lines[index], range: range) != nil {
                    lines[index] = "set_instance_assignment -name IO_STANDARD \"\(pin.ioStandard)\" -to \(signal)"
                    standardFound = true
                }
            }
            if !locationFound { lines.append("set_location_assignment \(pin.packagePin) -to \(signal)") }
            if !standardFound { lines.append("set_instance_assignment -name IO_STANDARD \"\(pin.ioStandard)\" -to \(signal)") }
            try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
            constraintsRevision += 1
            diagnostics = ProjectValidator.validate(project: project, root: rootURL, board: board)
            invalidateGeneratedResults()
        } catch { lastError = error.localizedDescription }
    }

    func refreshToolchain() {
        Task {
            do {
                let manifest = try BundledResources.toolchainManifest()
                var health = await toolchain.health(manifest: manifest)
                if health.contains(where: { !$0.isAvailable }), try await toolchain.installBundledBootstrapIfAvailable(manifest: manifest) {
                    health = await toolchain.health(manifest: manifest)
                }
                toolHealth = health
            } catch { lastError = error.localizedDescription }
        }
    }

    func chooseToolchainArchive() {
        let panel = NSOpenPanel()
        panel.title = "Install Managed FPGA Toolchain"
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        Task {
            do {
                let manifest = try BundledResources.toolchainManifest()
                try await toolchain.install(archive: archive, manifest: manifest)
                toolHealth = await toolchain.health(manifest: manifest)
            } catch { lastError = error.localizedDescription }
        }
    }

    private func finishOperation() {
        if let powerActivity { ProcessInfo.processInfo.endActivity(powerActivity); self.powerActivity = nil }
        AppLifecycleDelegate.flashWriteActive = false
        isRunning = false
        operation = nil
    }

    private func invalidateGeneratedResults() {
        lastValidationSucceeded = false
        lastBuildSucceeded = false
        lastProgrammedSRAM = false
        lastProgrammedSRAMSHA256 = nil
        lastBuildFingerprint = nil
        flashCandidate = nil
        waveform = nil
    }

    private func makeProgrammingArtifact() throws -> ProgrammingArtifact {
        guard let project, let rootURL, lastBuildSucceeded, let lastBuildFingerprint else {
            throw FPGAStudioError.noBitstream
        }
        let currentFingerprint = try ProjectFingerprint.compute(project: project, root: rootURL)
        guard currentFingerprint == lastBuildFingerprint else {
            invalidateGeneratedResults()
            throw FPGAStudioError.unsupported("The project changed after the last build. Build it again before programming hardware.")
        }
        guard let url = latestBitstream, url.lastPathComponent == "design.rbf" else {
            throw FPGAStudioError.noBitstream
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard (HardwareSafetyPolicy.minimumBitstreamBytes...HardwareSafetyPolicy.maximumBitstreamBytes).contains(data.count) else {
            throw FPGAStudioError.unsupported("The generated bitstream has an unsafe size. Build the project again and inspect the build log.")
        }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return ProgrammingArtifact(
            url: url,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count,
            modifiedAt: values.contentModificationDate ?? Date(),
            projectFingerprint: currentFingerprint,
            boardID: board.id,
            device: board.device
        )
    }

    private var trustIdentifier: String? {
        guard let rootURL else { return nil }
        return SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var isCurrentProjectTrusted: Bool {
        guard let trustIdentifier else { return false }
        return Set(UserDefaults.standard.stringArray(forKey: "trustedSimulationProjects") ?? []).contains(trustIdentifier)
    }

    private func remember(_ url: URL) {
        var paths = recentProjects.map(\.path).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: "recentProjects")
        objectWillChange.send()
    }
}

private extension BuildAction {
    var isSimulation: Bool {
        if case .simulate = self { return true }
        return false
    }
    var isFlash: Bool {
        if case .programFlash(_) = self { return true }
        return false
    }
    var isProgramming: Bool {
        switch self {
        case .programSRAM, .programFlash: true
        default: false
        }
    }
}
