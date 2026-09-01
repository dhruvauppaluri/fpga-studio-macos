import XCTest
@testable import FPGAStudioCore

final class ManifestTests: XCTestCase {
    func testUnknownManifestFieldsSurviveRoundTrip() throws {
        let json = """
        {"schemaVersion":1,"name":"Demo","top":"top","board":"terasic-c5g","constraints":"c.qsf","sources":[],"future":{"enabled":true}}
        """
        let project = try JSONDecoder().decode(FPGAProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.extensions["future"], .object(["enabled": .bool(true)]))
        let encoded = try JSONEncoder().encode(project)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(object?["future"])
    }

    func testFutureSchemaIsReadOnly() throws {
        let project = FPGAProject(schemaVersion: 99, name: "Future", top: "top", sources: [])
        XCTAssertTrue(project.isReadOnly)
    }

    func testSafePathResolutionRejectsTraversal() throws {
        let root = URL(fileURLWithPath: "/tmp/fpga-project")
        XCTAssertThrowsError(try ProjectStore.resolve("../secret", under: root))
        XCTAssertThrowsError(try ProjectStore.resolve("/etc/passwd", under: root))
        XCTAssertEqual(try ProjectStore.resolve("rtl/top.sv", under: root).path, "/tmp/fpga-project/rtl/top.sv")
    }

    func testProjectNameCannotEscapeArtifactDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-unsafe-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try ProjectTemplateFactory.create(.blinky, language: .systemVerilog, name: "Safe", at: root)
        project.name = "../../outside"
        let issues = ProjectValidator.validate(project: project, root: root, board: try BundledResources.boardProfile())
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("filename-safe") })
    }
}

final class ConstraintTests: XCTestCase {
    func testQSFParsingAndValidation() throws {
        let board = try BundledResources.boardProfile()
        let text = """
        set_location_assignment PIN_R20 -to CLOCK_50_B5B
        set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to CLOCK_50_B5B
        set_location_assignment PIN_R20 -to LEDG[0]
        set_location_assignment PIN_NOTREAL -to mystery
        """
        let parsed = QSFParser.parse(text)
        XCTAssertEqual(parsed.count, 3)
        let issues = QSFParser.validate(parsed, against: board, requiredPorts: ["CLOCK_50_B5B", "CPU_RESET_n"])
        XCTAssertTrue(issues.contains { $0.message.contains("assigned to both") })
        XCTAssertTrue(issues.contains { $0.message.contains("package-pin profile") })
        XCTAssertTrue(issues.contains { $0.message.contains("CPU_RESET_n") })
    }

    func testDirectionMismatchIsRejected() throws {
        let board = try BundledResources.boardProfile()
        let assignment = PinAssignment(signal: "led", packagePin: "PIN_AC9", ioStandard: "1.2 V", line: 1)
        let issues = QSFParser.validate([assignment], against: board, requiredPorts: ["led"], portDirections: ["led": .output])
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("top-level output") })
    }

    func testTopPortExtraction() {
        let verilog = "module top(input logic clock, output logic [7:0] leds); endmodule"
        XCTAssertEqual(SourcePortExtractor.ports(in: verilog, language: .systemVerilog, top: "top"), ["clock", "leds"])
        let vhdl = "entity top is port (clock : in std_logic; led : out std_logic); end entity;"
        XCTAssertEqual(SourcePortExtractor.ports(in: vhdl, language: .vhdl, top: "top"), ["clock", "led"])
    }

    func testDiagnosticParser() {
        let result = DiagnosticParser.parse("rtl/top.sv:12:4: error: unexpected token", tool: "Verilator")
        XCTAssertEqual(result.first?.file, "rtl/top.sv")
        XCTAssertEqual(result.first?.line, 12)
        XCTAssertEqual(result.first?.column, 4)
        XCTAssertEqual(result.first?.severity, .error)
    }
}

final class WaveformTests: XCTestCase {
    func testParsesScalarVectorHierarchyAndTimescale() throws {
        let vcd = """
        $timescale 1 ns $end
        $scope module tb $end
        $var wire 1 ! clock $end
        $var wire 8 # pc [7:0] $end
        $upscope $end
        $enddefinitions $end
        #0
        0!
        b00000000 #
        #10
        1!
        b00000100 #
        #20
        0!
        """
        let document = try VCDParser.parse(vcd)
        XCTAssertEqual(document.timescale, "1 ns")
        XCTAssertEqual(document.endTime, 20)
        XCTAssertEqual(document.signals.count, 2)
        XCTAssertEqual(document.signals[0].qualifiedName, "tb.clock")
        XCTAssertEqual(document.signals[0].value(at: 15), "1")
        XCTAssertEqual(document.signals[1].formatted("00000100", radix: .hexadecimal), "0x4")
    }
}

final class LearningPathTests: XCTestCase {
    func testBlinkyIsTheRecommendedBeginnerTemplate() {
        XCTAssertEqual(ProjectTemplate.recommendedForBeginners, .blinky)
    }

    func testBeginnerPathStartsWithValidation() {
        XCTAssertEqual(LearningProgress().nextStep, .validate)
    }

    func testBeginnerPathAdvancesOneConceptAtATime() {
        XCTAssertEqual(LearningProgress(validated: true).nextStep, .simulate)
        XCTAssertEqual(LearningProgress(validated: true, simulated: true).nextStep, .build)
        XCTAssertEqual(LearningProgress(validated: true, simulated: true, built: true).nextStep, .connect)
        XCTAssertEqual(LearningProgress(validated: true, simulated: true, built: true, boardConnected: true).nextStep, .programSRAM)
    }

    func testBeginnerPathCompletesAfterSafeSRAMProgramming() {
        let progress = LearningProgress(validated: true, simulated: true, built: true, boardConnected: true, programmedSRAM: true)
        XCTAssertEqual(progress.nextStep, .complete)
        XCTAssertEqual(progress.completedCount, 5)
    }
}

final class TemplateTests: XCTestCase {
    func testRV32ITemplateIsScaffoldingNotFinishedCPU() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectTemplateFactory.create(.rv32i, language: .systemVerilog, name: "RV32 Lab", at: root)
        XCTAssertEqual(project.top, "c5g_top")
        let core = try String(contentsOf: root.appendingPathComponent("rtl/rv32i_core.sv"), encoding: .utf8)
        XCTAssertTrue(core.contains("TODO: implement your RV32I machine"))
        XCTAssertFalse(core.contains("case (instruction_data[6:0])"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sim/program.hex").path))
    }

    func testRV32ITemplateCompilesWithIcarusWhenAvailable() async throws {
        let locator = ToolchainLocator(managedRoot: FileManager.default.temporaryDirectory.appendingPathComponent("unused-managed-root"))
        guard let iverilog = locator.resolve("iverilog") else { throw XCTSkip("Icarus Verilog is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-rv32-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectTemplateFactory.create(.rv32i, language: .systemVerilog, name: "RV32 Lab", at: root)
        let service = ToolProcessService()
        let files = try project.sources.map { try ProjectStore.resolve($0.path, under: root).path }
        let result = try await service.run(.init(tool: "Icarus Verilog", executableURL: iverilog, arguments: ["-g2012", "-s", "rv32i_core_tb", "-o", root.appendingPathComponent("rv32-test").path] + files, workingDirectory: root))
        XCTAssertEqual(result.exitCode, 0, result.output)
    }

    func testBlinkyTemplateValidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectTemplateFactory.create(.blinky, language: .systemVerilog, name: "Blinky", at: root)
        let issues = ProjectValidator.validate(project: project, root: root, board: try BundledResources.boardProfile())
        XCTAssertFalse(issues.contains { $0.severity == .error }, "\(issues)")
    }
}

final class ProcessTests: XCTestCase {
    func testProcessUsesArgumentArrayWithoutShellExpansion() async throws {
        let service = ToolProcessService()
        let invocation = ToolInvocation(
            tool: "printf",
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "$(touch should-not-exist)"],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let result = try await service.run(invocation)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "$(touch should-not-exist)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("should-not-exist").path))
    }

    func testBlinkySimulationIntegrationWhenIcarusIsInstalled() async throws {
        let locator = ToolchainLocator(managedRoot: FileManager.default.temporaryDirectory.appendingPathComponent("unused-managed-root"))
        guard locator.resolve("iverilog") != nil else { throw XCTSkip("Icarus Verilog is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-simulation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectTemplateFactory.create(.blinky, language: .systemVerilog, name: "Blinky", at: root)
        let pipeline = BuildPipeline(locator: locator)
        let outcome = await pipeline.run(action: .simulate(test: try XCTUnwrap(project.tests.first)), project: project, root: root, board: try BundledResources.boardProfile())
        XCTAssertTrue(outcome.succeeded, outcome.log + "\n" + outcome.diagnostics.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(outcome.artifacts.contains { $0.kind == "VCD waveform" })
        let vcd = try XCTUnwrap(outcome.artifacts.first).path
        XCTAssertGreaterThan(try VCDParser.parse(url: URL(fileURLWithPath: vcd)).signals.count, 0)
    }

    func testUnsignedToolchainArchiveIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-toolchain-\(UUID().uuidString)")
        let archive = root.appendingPathComponent("toolchain.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not an archive".utf8).write(to: archive)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ToolchainManager(root: root.appendingPathComponent("installed"))
        let manifest = try BundledResources.toolchainManifest()
        do {
            try await manager.install(archive: archive, manifest: manifest)
            XCTFail("Unsigned archive should not install")
        } catch let error as FPGAStudioError {
            guard case .unsupported(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(message.contains("unsigned toolchain"))
        }
    }
}
