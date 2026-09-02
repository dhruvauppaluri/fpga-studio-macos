import CryptoKit
import Foundation

public enum BuildAction: Sendable {
    case validate
    case simulate(test: TestTarget)
    case build
    case detectDevice
    case programSRAM(artifact: ProgrammingArtifact)
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
            case .programSRAM(let artifact):
                return try await program(flash: false, artifact: artifact, project: project, board: board, root: root, buildRoot: buildRoot, onEvent: onEvent)
            case .programFlash(let artifact):
                return try await program(flash: true, artifact: artifact, project: project, board: board, root: root, buildRoot: buildRoot, onEvent: onEvent)
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
            let runtime = try locator.require("vvp")
            let executable = directory.appendingPathComponent("simulation")
            var arguments = ["-g2012", "-s", test.top, "-o", executable.path]
            let ivlResources = compiler.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/ivl")
            if FileManager.default.fileExists(atPath: ivlResources.path) {
                arguments.insert(contentsOf: ["-B", ivlResources.path], at: 0)
            }
            arguments.append(contentsOf: files.map(\.path))
            let compile = try await invoke("Icarus Verilog", compiler, arguments, directory, onEvent)
            log += compile.output
            var runtimeArguments: [String] = []
            let vvpModules = runtime.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/ivl")
            if FileManager.default.fileExists(atPath: vvpModules.path) {
                runtimeArguments += ["-M", vvpModules.path]
            }
            runtimeArguments.append(executable.path)
            let run = try await invoke("Icarus Verilog runtime", runtime, runtimeArguments, directory, onEvent)
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
        _ = try HardwareSafetyPolicy.validateDetection(result.output, board: board)
        return .init(succeeded: true, stage: .completed, log: result.output, diagnostics: [])
    }

    private func program(flash: Bool, artifact: ProgrammingArtifact, project: FPGAProject, board: BoardProfile, root: URL, buildRoot: URL, onEvent: EventHandler?) async throws -> BuildOutcome {
        let loader = try locator.require("openFPGALoader")
        if flash {
            guard board.isFlashProgrammingValidated else {
                throw FPGAStudioError.unsupported("Persistent flash is locked for this board because the upstream C5G flash path and this app's hardware acceptance are not validated.")
            }
        } else {
            guard board.isSRAMProgrammingValidated else {
                throw FPGAStudioError.unsupported("SRAM programming is locked because this board profile has not been hardware validated.")
            }
        }
        let release = buildRoot.appendingPathComponent("release")
        let fingerprint = try ProjectFingerprint.compute(project: project, root: root)
        let data = try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: fingerprint, releaseRoot: release)
        let temporaryCopy = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-studio-program-\(UUID().uuidString).rbf")
        try data.write(to: temporaryCopy, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: temporaryCopy) }
        onEvent?(flash ? .programmingFlash : .programmingSRAM, flash ? "Writing persistent EPCQ flash\n" : "Configuring volatile SRAM\n")
        let preflight = try await invoke("openFPGALoader", loader, ["-b", board.programmerBoard, "--detect"], root, onEvent)
        _ = try HardwareSafetyPolicy.validateDetection(preflight.output, board: board)
        var arguments = ["-b", board.programmerBoard, flash ? "--write-flash" : "--write-sram"]
        if flash { arguments.append("--verify") }
        arguments.append(temporaryCopy.path)
        let result = try await invoke("openFPGALoader", loader, arguments, root, onEvent)
        let postflight = try await invoke("openFPGALoader", loader, ["-b", board.programmerBoard, "--detect"], root, onEvent)
        _ = try HardwareSafetyPolicy.validateDetection(postflight.output, board: board)
        return .init(succeeded: true, stage: .completed, log: result.output + postflight.output, diagnostics: [], artifacts: [.init(kind: flash ? "Programmed flash" : "Programmed SRAM", path: artifact.url.path, createdAt: Date())])
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
