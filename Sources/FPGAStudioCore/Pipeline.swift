import CryptoKit
import Foundation

public enum BuildAction: Sendable {
    case validate
    case simulate(test: TestTarget)
    case build
    case detectDevice
    case programSRAM
    case programFlash(artifact: ProgrammingArtifact)
}

public actor BuildPipeline {
    public typealias EventHandler = @Sendable (BuildStage, String) -> Void

    private let locator: ToolchainLocator
    private let processes: ToolProcessService
    private var isBusy = false

    public init(locator: ToolchainLocator = .init(), processes: ToolProcessService = .init()) {
        self.locator = locator
        self.processes = processes
    }

    public func run(action: BuildAction, project: FPGAProject, root: URL, board: BoardProfile, onEvent: EventHandler? = nil) async -> BuildOutcome {
        guard !isBusy else {
            return .init(succeeded: false, stage: .failed, log: "", diagnostics: [.init(severity: .error, message: "A build already owns this project build directory.", tool: "Build")])
        }
        isBusy = true
        defer { isBusy = false }

        var log = ""
        var diagnostics = ProjectValidator.validate(project: project, root: root, board: board)
        onEvent?(.validating, "Validating project\n")
        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return .init(succeeded: false, stage: .failed, log: log, diagnostics: diagnostics)
        }
        if case .validate = action {
            return .init(succeeded: true, stage: .completed, log: "Project validation passed.\n", diagnostics: diagnostics)
        }

        do {
            let buildRoot = try ProjectStore.resolve(".fpga/build", under: root)
            try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
            switch action {
            case .simulate(let test):
                let outcome = try await simulate(test: test, project: project, root: root, buildRoot: buildRoot, onEvent: onEvent)
                return merge(outcome, validation: diagnostics)
            case .build:
                let outcome = try await build(project: project, root: root, buildRoot: buildRoot, board: board, onEvent: onEvent)
                return merge(outcome, validation: diagnostics)
            case .detectDevice:
                return try await detect(board: board, root: root, onEvent: onEvent)
            case .programSRAM:
                return try await program(flash: false, confirmedArtifact: nil, board: board, root: root, buildRoot: buildRoot, onEvent: onEvent)
            case .programFlash(let artifact):
                return try await program(flash: true, confirmedArtifact: artifact, board: board, root: root, buildRoot: buildRoot, onEvent: onEvent)
            case .validate:
                fatalError("Handled above")
            }
        } catch let error as FPGAStudioError {
            if case .commandFailed(let tool, _, let output) = error {
                log += output
                diagnostics.append(contentsOf: DiagnosticParser.parse(output, tool: tool))
            } else {
                diagnostics.append(.init(severity: .error, message: error.localizedDescription, tool: "FPGA Studio"))
            }
            return .init(succeeded: false, stage: .failed, log: log, diagnostics: diagnostics)
        } catch {
            diagnostics.append(.init(severity: .error, message: error.localizedDescription, tool: "FPGA Studio"))
            return .init(succeeded: false, stage: .failed, log: log, diagnostics: diagnostics)
        }
    }

    public func cancel() async { await processes.cancelAll() }

    private func simulate(test: TestTarget, project: FPGAProject, root: URL, buildRoot: URL, onEvent: EventHandler?) async throws -> BuildOutcome {
        let directory = buildRoot.appendingPathComponent("simulation", isDirectory: true)
        try recreateDirectory(directory)
        onEvent?(.simulating, "Simulating \(test.name)\n")
        let files = try test.sources.map { try ProjectStore.resolve($0, under: root) }
        var log = ""

        switch test.language {
        case .verilog, .systemVerilog:
            let compiler = try locator.require("iverilog")
            let executable = directory.appendingPathComponent("simulation")
            var arguments = ["-g2012", "-s", test.top, "-o", executable.path]
            arguments.append(contentsOf: files.map(\.path))
            let compile = try await invoke("Icarus Verilog", compiler, arguments, directory, onEvent)
            log += compile.output
            let run = try await invoke("Simulation", executable, [], directory, onEvent)
            log += run.output
        case .vhdl:
            let ghdl = try locator.require("ghdl")
            for file in files {
                let result = try await invoke("GHDL", ghdl, ["-a", "--std=08", file.path], directory, onEvent)
                log += result.output
            }
            log += try await invoke("GHDL", ghdl, ["-e", "--std=08", test.top], directory, onEvent).output
            log += try await invoke("GHDL", ghdl, ["-r", "--std=08", test.top, "--vcd=waves.vcd"], directory, onEvent).output
        }
        let waveform = directory.appendingPathComponent("waves.vcd")
        let artifacts = FileManager.default.fileExists(atPath: waveform.path)
            ? [BuildArtifact(kind: "VCD waveform", path: waveform.path, createdAt: Date())] : []
        return .init(succeeded: true, stage: .completed, log: log, diagnostics: [], artifacts: artifacts)
    }

    private func build(project: FPGAProject, root: URL, buildRoot: URL, board: BoardProfile, onEvent: EventHandler?) async throws -> BuildOutcome {
        let directory = buildRoot.appendingPathComponent("release", isDirectory: true)
        try recreateDirectory(directory)
        let yosys = try locator.require("yosys")
        let nextpnr = try locator.require("nextpnr-mistral")
        let sourceFiles = project.sources.filter { !$0.isTestbench }
        let script = try yosysScript(project: project, sources: sourceFiles, root: root, output: directory.appendingPathComponent("design.json"))
        let scriptURL = directory.appendingPathComponent("synthesize.ys")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)

        var log = ""
        if !sourceFiles.contains(where: { $0.language == .vhdl }), let verilator = locator.resolve("verilator") {
            onEvent?(.validating, "Linting synthesizable RTL with Verilator\n")
            let sourcePaths = try sourceFiles.map { try ProjectStore.resolve($0.path, under: root).path }
            log += try await invoke("Verilator", verilator, ["--lint-only", "--timing", "-Wall", "-Wno-fatal", "--top-module", project.top] + sourcePaths, directory, onEvent).output
        }
        onEvent?(.synthesizing, "Synthesizing \(project.top)\n")
        var yosysArguments: [String] = []
        if sourceFiles.contains(where: { $0.language == .vhdl }) { yosysArguments += ["-m", "ghdl"] }
        yosysArguments += ["-s", scriptURL.path]
        log += try await invoke("Yosys", yosys, yosysArguments, directory, onEvent).output
        onEvent?(.routing, "Placing and routing for \(board.device) with seed \(project.synthesis.routingSeed)\n")
        let rbf = directory.appendingPathComponent("design.rbf")
        let report = directory.appendingPathComponent("report.json")
        let qsf = try ProjectStore.resolve(project.constraints, under: root)
        let route = try await invoke("nextpnr-mistral", nextpnr, [
            "--device", board.device,
            "--json", directory.appendingPathComponent("design.json").path,
            "--qsf", qsf.path,
            "--seed", String(project.synthesis.routingSeed),
            "--report", report.path,
            "--rbf", rbf.path
        ], directory, onEvent)
        log += route.output
        let artifacts = [
            BuildArtifact(kind: "JSON netlist", path: directory.appendingPathComponent("design.json").path, createdAt: Date()),
            BuildArtifact(kind: "RBF bitstream", path: rbf.path, createdAt: Date()),
            BuildArtifact(kind: "Timing and utilization", path: report.path, createdAt: Date())
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        return .init(succeeded: true, stage: .completed, log: log, diagnostics: [], artifacts: artifacts)
    }

    private func detect(board: BoardProfile, root: URL, onEvent: EventHandler?) async throws -> BuildOutcome {
        let loader = try locator.require("openFPGALoader")
        onEvent?(.detecting, "Inspecting the C5G JTAG chain\n")
        let result = try await invoke("openFPGALoader", loader, ["-b", board.programmerBoard, "--detect"], root, onEvent)
        return .init(succeeded: true, stage: .completed, log: result.output, diagnostics: [])
    }

    private func program(flash: Bool, confirmedArtifact: ProgrammingArtifact?, board: BoardProfile, root: URL, buildRoot: URL, onEvent: EventHandler?) async throws -> BuildOutcome {
        let loader = try locator.require("openFPGALoader")
        let release = buildRoot.appendingPathComponent("release")
        let entries = try FileManager.default.contentsOfDirectory(at: release, includingPropertiesForKeys: [.contentModificationDateKey])
        let bitstreams = entries.filter { $0.pathExtension.lowercased() == "rbf" }.sorted { lhs, rhs in
            let leftValues = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
            let rightValues = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
            let leftDate = leftValues?.contentModificationDate ?? Date.distantPast
            let rightDate = rightValues?.contentModificationDate ?? Date.distantPast
            return leftDate > rightDate
        }
        guard let newestBitstream = bitstreams.first else { throw FPGAStudioError.noBitstream }
        let bitstream: URL
        var temporaryCopy: URL?
        if flash {
            guard let confirmedArtifact else { throw FPGAStudioError.noBitstream }
            let releaseRoot = release.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let confirmedURL = confirmedArtifact.url.standardizedFileURL.resolvingSymlinksInPath()
            guard confirmedURL.path.hasPrefix(releaseRoot), confirmedURL.pathExtension.lowercased() == "rbf" else {
                throw FPGAStudioError.unsafePath(confirmedArtifact.url.path)
            }
            let data = try Data(contentsOf: confirmedURL, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(confirmedArtifact.sha256) == .orderedSame,
                  data.count == confirmedArtifact.byteCount else {
                throw FPGAStudioError.unsupported("The confirmed bitstream changed after the flash sheet was shown. Confirm it again before programming.")
            }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-studio-flash-\(UUID().uuidString).rbf")
            try data.write(to: copy, options: [.atomic, .completeFileProtection])
            temporaryCopy = copy
            bitstream = copy
        } else {
            bitstream = newestBitstream
        }
        defer { if let temporaryCopy { try? FileManager.default.removeItem(at: temporaryCopy) } }
        onEvent?(flash ? .programmingFlash : .programmingSRAM, flash ? "Writing persistent EPCQ flash\n" : "Configuring volatile SRAM\n")
        _ = try await invoke("openFPGALoader", loader, ["-b", board.programmerBoard, "--detect"], root, onEvent)
        var arguments = ["-b", board.programmerBoard]
        if flash { arguments.append("--write-flash") }
        arguments.append(bitstream.path)
        let result = try await invoke("openFPGALoader", loader, arguments, root, onEvent)
        if flash { _ = try await invoke("openFPGALoader", loader, ["-b", board.programmerBoard, "--detect"], root, onEvent) }
        let reportedPath = confirmedArtifact?.url.path ?? bitstream.path
        return .init(succeeded: true, stage: .completed, log: result.output, diagnostics: [], artifacts: [.init(kind: flash ? "Programmed flash" : "Programmed SRAM", path: reportedPath, createdAt: Date())])
    }

    private func invoke(_ name: String, _ executable: URL, _ arguments: [String], _ directory: URL, _ onEvent: EventHandler?) async throws -> ToolResult {
        onEvent?(.idle, "$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n")
        let result = try await processes.run(.init(tool: name, executableURL: executable, arguments: arguments, workingDirectory: directory)) { chunk in
            onEvent?(.idle, chunk)
        }
        guard result.exitCode == 0 else { throw FPGAStudioError.commandFailed(tool: name, code: result.exitCode, output: result.output) }
        return result
    }

    private func yosysScript(project: FPGAProject, sources: [ProjectSource], root: URL, output: URL) throws -> String {
        let vhdl = sources.filter { $0.language == .vhdl }
        let verilog = sources.filter { $0.language != .vhdl }
        var lines: [String] = []
        if !vhdl.isEmpty {
            let files = try vhdl.map { try ProjectStore.resolve($0.path, under: root).path }.map(Self.yosysQuote).joined(separator: " ")
            lines.append("ghdl --std=08 \(files) -e \(Self.yosysQuote(project.top))")
        }
        if !verilog.isEmpty {
            let files = try verilog.map { try ProjectStore.resolve($0.path, under: root).path }.map(Self.yosysQuote).joined(separator: " ")
            lines.append("read_verilog -sv \(files)")
        }
        lines.append("hierarchy -check -top \(Self.yosysQuote(project.top))")
        // The supported profile deliberately maps inferred memories to logic before Intel ALM mapping.
        if !project.synthesis.enableBlockRAM && !project.synthesis.enableLUTRAM { lines.append("memory_map") }
        if !project.synthesis.enableDSP { lines.append("alumacc; techmap") }
        lines.append("synth_intel_alm -top \(Self.yosysQuote(project.top))")
        lines.append("write_json \(Self.yosysQuote(output.path))")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func yosysQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func recreateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func merge(_ outcome: BuildOutcome, validation: [Diagnostic]) -> BuildOutcome {
        .init(succeeded: outcome.succeeded, stage: outcome.stage, log: outcome.log, diagnostics: validation + outcome.diagnostics, artifacts: outcome.artifacts)
    }
}
