import CryptoKit
import XCTest
@testable import FPGAStudioCore

final class EditorSupportTests: XCTestCase {
    func testLogicalLineIndexHandlesBlankAndTrailingLines() {
        let empty = LogicalLineIndex("")
        XCTAssertEqual(empty.lineCount, 1)
        XCTAssertEqual(empty.start(ofLine: 1), 0)

        let trailing = LogicalLineIndex("alpha\nbeta\n")
        XCTAssertEqual(trailing.lineCount, 3)
        XCTAssertEqual(trailing.start(ofLine: 3), 11)
        XCTAssertEqual(trailing.lineNumber(atUTF16Offset: 11), 3)
    }

    func testLogicalLineIndexAppliesInsertionDeletionAndMultilinePaste() {
        var text = "alpha\nbeta"
        var index = LogicalLineIndex(text)

        text = "alpha\n\nbeta"
        index.applyEdit(to: text, editedRange: NSRange(location: 6, length: 1), changeInLength: 1)
        XCTAssertEqual(index.lineStarts, [0, 6, 7])

        text = "alpha\nbeta"
        index.applyEdit(to: text, editedRange: NSRange(location: 5, length: 0), changeInLength: -1)
        XCTAssertEqual(index.lineStarts, [0, 6])

        text = "alpha\nbeta\none\ntwo\n"
        index.applyEdit(to: text, editedRange: NSRange(location: 10, length: 9), changeInLength: 9)
        XCTAssertEqual(index.lineStarts, [0, 6, 11, 15, 19])
    }

    func testLogicalLineIndexStaysFastAtOneHundredThousandLines() {
        let text = String(repeating: "x\n", count: 99_999) + "x"
        var index = LogicalLineIndex(text)
        XCTAssertEqual(index.lineCount, 100_000)

        let mutable = NSMutableString(string: text)
        let insertion = 100_000
        mutable.insert("\n", at: insertion)
        let updated = mutable as String
        let start = ContinuousClock.now
        index.applyEdit(to: updated, editedRange: NSRange(location: insertion, length: 1), changeInLength: 1)
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(index.lineCount, 100_001)
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testSyntaxLexerPropagatesBlockCommentsAndFindsTokens() {
        let first = HDLSyntaxLexer.lexLine(
            "logic ready; /* explanation",
            language: .systemVerilog,
            startsInBlockComment: false
        )
        XCTAssertTrue(first.endsInBlockComment)
        XCTAssertTrue(first.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(first.tokens.contains { $0.kind == .comment })

        let second = HDLSyntaxLexer.lexLine(
            "continued */ module core;",
            language: .systemVerilog,
            startsInBlockComment: first.endsInBlockComment
        )
        XCTAssertFalse(second.endsInBlockComment)
        XCTAssertTrue(second.tokens.contains { $0.kind == .comment })
        XCTAssertTrue(second.tokens.contains { $0.kind == .keyword })
    }

    func testSyntaxLexerHandlesVHDLCommentsStringsAndNumbers() {
        let result = HDLSyntaxLexer.lexLine(
            "signal count : integer := 42; -- \"ignored\" 99",
            language: .vhdl,
            startsInBlockComment: false
        )
        XCTAssertTrue(result.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(result.tokens.contains { $0.kind == .number })
        XCTAssertTrue(result.tokens.contains { $0.kind == .comment })
        XCTAssertFalse(result.endsInBlockComment)
    }

    func testDocumentSaveCoordinatorRejectsAnOlderRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-editor-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("top.sv")
        let saver = DocumentSaveCoordinator()

        let acceptedNew = try await saver.write(documentID: "top.sv", revision: 2, text: "new", to: url)
        let acceptedOld = try await saver.write(documentID: "top.sv", revision: 1, text: "old", to: url)
        XCTAssertTrue(acceptedNew)
        XCTAssertFalse(acceptedOld)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
    }
}

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

    func testWorkspaceProfilesChangePresentationDefaultsNotCapabilities() {
        XCTAssertEqual(ExperienceProfile.allCases, [.beginner, .hobbyist, .professional])
        XCTAssertTrue(ExperienceProfile.beginner.showsLearningGuideByDefault)
        XCTAssertFalse(ExperienceProfile.hobbyist.showsLearningGuideByDefault)
        XCTAssertTrue(ExperienceProfile.professional.showsAdvancedControlsByDefault)
        XCTAssertEqual(ExperienceProfile.beginner.recommendedTemplate, .blinky)
        XCTAssertEqual(ExperienceProfile.hobbyist.recommendedTemplate, .blank)
        XCTAssertEqual(ExperienceProfile.professional.recommendedTemplate, .blank)
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
    func testBlinkyTemplatesContainEditableSourceForEveryLanguage() throws {
        for language in HDLLanguage.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-blinky-source-\(language.rawValue)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            let project = try ProjectTemplateFactory.create(.blinky, language: language, name: "Editable Blinky", at: root)
            guard let source = project.sources.first(where: { !$0.isTestbench }) else {
                return XCTFail("Blinky must include a synthesizable source file for \(language.displayName)")
            }
            let sourceURL = try ProjectStore.resolve(source.path, under: root)
            let original = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(original.contains(language == .vhdl ? "entity blinky" : "module blinky"))

            let edited = original + "\n\(language == .vhdl ? "--" : "//") edit smoke test\n"
            try Data(edited.utf8).write(to: sourceURL, options: .atomic)
            XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), edited)
        }
    }

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

// MARK: - Hardware Safety Guard Rails

final class HardwareSafetyTests: XCTestCase {

    // MARK: validateDetection

    /// openFPGALoader prints `idcode 0x%x` (no zero-padding).  The C5G's real
    /// IDCODE 0x02b020dd has a leading-zero nibble, so the tool emits 7 hex
    /// digits: `idcode 0x2b020dd`.  This must succeed.
    func testDetectionSucceedsWithUnpaddedIDCode() throws {
        let board = try BundledResources.boardProfile()
        let output = """
        Jtag frequency : requested 6000000Hz -> real 6000000Hz
        index 0:
        \tidcode 0x2b020dd
        \tmanufacturer altera
        \tfamily cyclone V
        \tmodel  5CGT*5/5CGX*5
        \tirlength 10
        """
        let device = try HardwareSafetyPolicy.validateDetection(output, board: board)
        XCTAssertEqual(device.idCode, "0x02b020dd")
    }

    /// If the IDCODE happens to be zero-padded (e.g. a patched build or future
    /// openFPGALoader release), the canonical compare must still match.
    func testDetectionSucceedsWithZeroPaddedIDCode() throws {
        let board = try BundledResources.boardProfile()
        let output = """
        index 0:
        \tidcode 0x02b020dd
        \tmanufacturer altera
        \tfamily cyclone V
        \tmodel  5CGT*5/5CGX*5
        \tirlength 10
        """
        let device = try HardwareSafetyPolicy.validateDetection(output, board: board)
        XCTAssertEqual(device.idCode, "0x02b020dd")
    }

    func testDetectionRejectsWrongIDCode() throws {
        let board = try BundledResources.boardProfile()
        let output = """
        index 0:
        \tidcode 0xdeadbeef
        \tmanufacturer altera
        \tfamily cyclone V
        \tmodel  5CGT*5/5CGX*5
        """
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateDetection(output, board: board)) { error in
            guard case FPGAStudioError.unsupported(let msg) = error else { return XCTFail("Wrong error type") }
            XCTAssertTrue(msg.contains("does not match"), msg)
        }
    }

    func testDetectionRejectsMultipleDevicesOnChain() throws {
        let board = try BundledResources.boardProfile()
        let output = """
        index 0:
        \tidcode 0x2b020dd
        \tmanufacturer altera
        index 1:
        \tidcode 0x2b020dd
        \tmanufacturer altera
        \tfamily cyclone V
        \tmodel  5CGT*5/5CGX*5
        """
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateDetection(output, board: board)) { error in
            guard case FPGAStudioError.unsupported(let msg) = error else { return XCTFail("Wrong error type") }
            XCTAssertTrue(msg.contains("missing or ambiguous"), msg)
        }
    }

    func testDetectionRejectsMissingManufacturer() throws {
        let board = try BundledResources.boardProfile()
        let output = """
        index 0:
        \tidcode 0x2b020dd
        \tfamily cyclone V
        \tmodel  5CGT*5/5CGX*5
        """
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateDetection(output, board: board)) { error in
            guard case FPGAStudioError.unsupported(let msg) = error else { return XCTFail("Wrong error type") }
            XCTAssertTrue(msg.contains("manufacturer"), msg)
        }
    }

    func testDetectionRejectsMissingModel() throws {
        let board = try BundledResources.boardProfile()
        let output = """
        index 0:
        \tidcode 0x2b020dd
        \tmanufacturer altera
        \tfamily cyclone V
        """
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateDetection(output, board: board)) { error in
            guard case FPGAStudioError.unsupported(let msg) = error else { return XCTFail("Wrong error type") }
            XCTAssertTrue(msg.contains("model does not match"), msg)
        }
    }

    func testDetectionRejectsEmptyOutput() throws {
        let board = try BundledResources.boardProfile()
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateDetection("", board: board)) { error in
            guard case FPGAStudioError.unsupported(let msg) = error else { return XCTFail("Wrong error type") }
            XCTAssertTrue(msg.contains("missing or ambiguous"), msg)
        }
    }

    // MARK: canonicalIDCode

    func testCanonicalIDCodePadding() {
        XCTAssertEqual(HardwareSafetyPolicy.canonicalIDCode("0x2b020dd"), "0x02b020dd")
        XCTAssertEqual(HardwareSafetyPolicy.canonicalIDCode("0x02b020dd"), "0x02b020dd")
        XCTAssertEqual(HardwareSafetyPolicy.canonicalIDCode("0X02B020DD"), "0x02b020dd")
        XCTAssertEqual(HardwareSafetyPolicy.canonicalIDCode("2b020dd"), "0x02b020dd")
        XCTAssertEqual(HardwareSafetyPolicy.canonicalIDCode("0x0"), "0x00000000")
        XCTAssertNil(HardwareSafetyPolicy.canonicalIDCode(""))
        XCTAssertNil(HardwareSafetyPolicy.canonicalIDCode("0x"))
        XCTAssertNil(HardwareSafetyPolicy.canonicalIDCode("notahex"))
    }

    // MARK: validateArtifact

    private func makeTestArtifact(board: BoardProfile, releaseRoot: URL) throws -> (ProgrammingArtifact, Data) {
        try FileManager.default.createDirectory(at: releaseRoot, withIntermediateDirectories: true)
        // A 2 KiB fake bitstream — above the 1 KiB minimum, well below the 64 MiB max
        let bitstreamData = Data(repeating: 0xAB, count: 2048)
        let bitstreamURL = releaseRoot.appendingPathComponent("design.rbf")
        try bitstreamData.write(to: bitstreamURL, options: .atomic)
        let sha = CryptoKit.SHA256.hash(data: bitstreamData).map { String(format: "%02x", $0) }.joined()
        let artifact = ProgrammingArtifact(
            url: bitstreamURL,
            sha256: sha,
            byteCount: bitstreamData.count,
            modifiedAt: Date(),
            projectFingerprint: "test-fingerprint",
            boardID: board.id,
            device: board.device
        )
        return (artifact, bitstreamData)
    }

    func testValidateArtifactAcceptsGoodBitstream() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        let (artifact, expected) = try makeTestArtifact(board: board, releaseRoot: releaseRoot)
        let data = try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "test-fingerprint", releaseRoot: releaseRoot)
        XCTAssertEqual(data, expected)
    }

    func testValidateArtifactRejectsWrongBoard() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        var (artifact, _) = try makeTestArtifact(board: board, releaseRoot: releaseRoot)
        artifact.boardID = "wrong-board"
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "test-fingerprint", releaseRoot: releaseRoot))
    }

    func testValidateArtifactRejectsWrongDevice() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        var (artifact, _) = try makeTestArtifact(board: board, releaseRoot: releaseRoot)
        artifact.device = "WRONG_DEVICE"
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "test-fingerprint", releaseRoot: releaseRoot))
    }

    func testValidateArtifactRejectsStaleFingerprint() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        let (artifact, _) = try makeTestArtifact(board: board, releaseRoot: releaseRoot)
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "different-fingerprint", releaseRoot: releaseRoot))
    }

    func testValidateArtifactRejectsTamperedBitstream() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        let (artifact, _) = try makeTestArtifact(board: board, releaseRoot: releaseRoot)
        // Tamper with the file after artifact was constructed
        try Data(repeating: 0xFF, count: 2048).write(to: artifact.url, options: .atomic)
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "test-fingerprint", releaseRoot: releaseRoot))
    }

    func testValidateArtifactRejectsPathOutsideRelease() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: releaseRoot, withIntermediateDirectories: true)
        // Put the bitstream outside the release directory
        let escapedDir = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: escapedDir, withIntermediateDirectories: true)
        let bitstreamData = Data(repeating: 0xAB, count: 2048)
        let escapedURL = escapedDir.appendingPathComponent("design.rbf")
        try bitstreamData.write(to: escapedURL, options: .atomic)
        let sha = CryptoKit.SHA256.hash(data: bitstreamData).map { String(format: "%02x", $0) }.joined()
        let artifact = ProgrammingArtifact(url: escapedURL, sha256: sha, byteCount: bitstreamData.count, modifiedAt: Date(), projectFingerprint: "fp", boardID: board.id, device: board.device)
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "fp", releaseRoot: releaseRoot))
    }

    func testValidateArtifactRejectsWrongFilename() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: releaseRoot, withIntermediateDirectories: true)
        let bitstreamData = Data(repeating: 0xAB, count: 2048)
        let badNameURL = releaseRoot.appendingPathComponent("evil.rbf")
        try bitstreamData.write(to: badNameURL, options: .atomic)
        let sha = CryptoKit.SHA256.hash(data: bitstreamData).map { String(format: "%02x", $0) }.joined()
        let artifact = ProgrammingArtifact(url: badNameURL, sha256: sha, byteCount: bitstreamData.count, modifiedAt: Date(), projectFingerprint: "fp", boardID: board.id, device: board.device)
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "fp", releaseRoot: releaseRoot))
    }

    func testValidateArtifactRejectsTooSmallBitstream() throws {
        let board = try BundledResources.boardProfile()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRoot = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: releaseRoot, withIntermediateDirectories: true)
        let tiny = Data(repeating: 0xAB, count: 100)  // below 1 KiB minimum
        let url = releaseRoot.appendingPathComponent("design.rbf")
        try tiny.write(to: url, options: .atomic)
        let sha = CryptoKit.SHA256.hash(data: tiny).map { String(format: "%02x", $0) }.joined()
        let artifact = ProgrammingArtifact(url: url, sha256: sha, byteCount: tiny.count, modifiedAt: Date(), projectFingerprint: "fp", boardID: board.id, device: board.device)
        XCTAssertThrowsError(try HardwareSafetyPolicy.validateArtifact(artifact, board: board, projectFingerprint: "fp", releaseRoot: releaseRoot))
    }

    // MARK: IO standard mismatch is now a blocking error

    func testIOStandardMismatchIsError() throws {
        let board = try BundledResources.boardProfile()
        // PIN_R20 is CLOCK_50_B5B, validated as "3.3-V LVTTL"
        let assignment = PinAssignment(signal: "CLOCK_50_B5B", packagePin: "PIN_R20", ioStandard: "2.5 V", line: 1)
        let issues = QSFParser.validate([assignment], against: board)
        let mismatch = issues.first { $0.message.contains("uses 2.5 V") }
        XCTAssertNotNil(mismatch)
        XCTAssertEqual(mismatch?.severity, .error, "IO standard mismatch must be an error — wrong voltage is an electrical damage vector")
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

    func testManagedProcessPathDoesNotAddPackageManagerFallbacks() async throws {
        let service = ToolProcessService()
        let invocation = ToolInvocation(
            tool: "env",
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let result = try await service.run(invocation)
        let pathLine = try XCTUnwrap(result.output.split(separator: "\n").first { $0.hasPrefix("PATH=") })
        XCTAssertFalse(pathLine.contains("/opt/homebrew/bin"))
        XCTAssertFalse(pathLine.contains("/usr/local/bin"))
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

    func testBlinkyVHDLSimulationIntegrationWhenGHDLIsInstalled() async throws {
        let locator = ToolchainLocator(managedRoot: FileManager.default.temporaryDirectory.appendingPathComponent("unused-managed-root"))
        guard locator.resolve("ghdl") != nil else { throw XCTSkip("GHDL is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-vhdl-simulation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectTemplateFactory.create(.blinky, language: .vhdl, name: "BlinkyVHDL", at: root)
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

    func testSignedToolchainArchiveMustContainEveryRuntimeExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-toolchain-incomplete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try BundledResources.toolchainManifest()
        let archive = try makeSignedToolchainArchive(root: root, manifest: &manifest, excluding: "mistral-cv")
        let manager = ToolchainManager(root: root.appendingPathComponent("installed"))

        do {
            try await manager.install(archive: archive, manifest: manifest)
            XCTFail("An incomplete signed archive should not install")
        } catch let error as FPGAStudioError {
            guard case .invalidProject(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(message.contains("mistral-cv"))
        }
    }

    func testSignedToolchainArchiveRequiresYosysABCCompanion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-toolchain-no-abc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try BundledResources.toolchainManifest()
        let archive = try makeSignedToolchainArchive(root: root, manifest: &manifest, excluding: "yosys-abc")
        let manager = ToolchainManager(root: root.appendingPathComponent("installed"))

        do {
            try await manager.install(archive: archive, manifest: manifest)
            XCTFail("A signed archive without yosys-abc should not install")
        } catch let error as FPGAStudioError {
            guard case .invalidProject(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(message.contains("yosys-abc"))
        }
    }

    func testCompleteSignedToolchainArchiveInstallsAndActivates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fpga-toolchain-complete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try BundledResources.toolchainManifest()
        manifest.version = "test-\(UUID().uuidString)"
        let archive = try makeSignedToolchainArchive(root: root, manifest: &manifest)
        let installed = root.appendingPathComponent("installed")
        let manager = ToolchainManager(root: installed)

        try await manager.install(archive: archive, manifest: manifest)

        let locator = ToolchainLocator(managedRoot: installed)
        XCTAssertNotNil(locator.resolve("ghdl"))
        XCTAssertNotNil(locator.resolve("ghdl1-llvm"))
        XCTAssertNotNil(locator.resolve("yosys-abc"))
        XCTAssertNotNil(locator.resolve("vvp"))
        XCTAssertNotNil(locator.resolve("verilator_bin"))
        let installedVersions = try await manager.installedVersions()
        XCTAssertEqual(installedVersions, [manifest.version])
    }

    private func makeSignedToolchainArchive(root: URL, manifest: inout ToolchainManifest, excluding excluded: String? = nil) throws -> URL {
        let payload = root.appendingPathComponent("payload")
        let bin = payload.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var executables = Set(manifest.tools.map(\.executable))
        executables.formUnion(["yosys-abc", "vvp", "verilator_bin", "ghdl1-llvm"])
        for executable in executables where executable != excluded {
            let url = bin.appendingPathComponent(executable)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let archive = root.appendingPathComponent("toolchain.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", payload.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let archiveData = try Data(contentsOf: archive)
        let key = Curve25519.Signing.PrivateKey()
        manifest.archiveSHA256 = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        manifest.archiveSignature = try key.signature(for: archiveData).base64EncodedString()
        manifest.signingPublicKey = key.publicKey.rawRepresentation.base64EncodedString()
        return archive
    }
}
