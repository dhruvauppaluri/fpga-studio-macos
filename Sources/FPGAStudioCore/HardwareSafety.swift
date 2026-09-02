import CryptoKit
import Foundation

public struct DetectedJTAGDevice: Equatable, Sendable {
    public var idCode: String
    public var rawOutput: String
}

public enum ProjectFingerprint {
    public static func compute(project: FPGAProject, root: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()

        func update(_ label: String, _ data: Data) {
            let labelData = Data(label.utf8)
            hasher.update(data: withUnsafeBytes(of: UInt64(labelData.count).bigEndian) { Data($0) })
            hasher.update(data: labelData)
            hasher.update(data: withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) })
            hasher.update(data: data)
        }

        update("fpga-project.json", try encoder.encode(project))
        for source in project.sources {
            let url = try ProjectStore.resolve(source.path, under: root)
            update(source.path, try Data(contentsOf: url, options: [.mappedIfSafe]))
        }
        let constraints = try ProjectStore.resolve(project.constraints, under: root)
        update(project.constraints, try Data(contentsOf: constraints, options: [.mappedIfSafe]))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum HardwareSafetyPolicy {
    public static let minimumBitstreamBytes = 1_024
    public static let maximumBitstreamBytes = 64 * 1_024 * 1_024

    public static func validateDetection(_ output: String, board: BoardProfile) throws -> DetectedJTAGDevice {
        let expected = Set((board.expectedJTAGIDCodes ?? []).compactMap(canonicalIDCode))
        guard !expected.isEmpty else {
            throw FPGAStudioError.unsupported("Programming is locked because this board profile has no verified JTAG identity.")
        }

        let expression = try NSRegularExpression(pattern: #"(?i)idcode\s+(0x[0-9a-f]{1,8})"#)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let detected = expression.matches(in: output, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range(at: 1), in: output) else { return nil }
            return canonicalIDCode(String(output[valueRange]))
        }
        guard detected.count == 1, let idCode = detected.first else {
            throw FPGAStudioError.unsupported("Programming stopped because the JTAG chain is missing or ambiguous. Disconnect other JTAG devices and detect the C5G again.")
        }
        guard expected.contains(idCode) else {
            throw FPGAStudioError.unsupported("Programming stopped because JTAG device \(idCode) does not match the expected C5G device.")
        }

        let normalizedOutput = output.lowercased()
        let modelTokens = board.expectedJTAGModels ?? []
        guard modelTokens.isEmpty || modelTokens.contains(where: { normalizedOutput.contains($0.lowercased()) }) else {
            throw FPGAStudioError.unsupported("Programming stopped because the detected FPGA model does not match the C5G profile.")
        }
        guard normalizedOutput.contains("manufacturer") && normalizedOutput.contains("altera") else {
            throw FPGAStudioError.unsupported("Programming stopped because the expected Altera/Intel manufacturer identity was not reported.")
        }
        return .init(idCode: idCode, rawOutput: output)
    }

    public static func validateArtifact(_ artifact: ProgrammingArtifact, board: BoardProfile, projectFingerprint: String, releaseRoot: URL) throws -> Data {
        guard artifact.boardID == board.id, artifact.device == board.device else {
            throw FPGAStudioError.unsupported("Programming stopped because the bitstream was built for a different board or FPGA device.")
        }
        guard artifact.projectFingerprint == projectFingerprint else {
            throw FPGAStudioError.unsupported("Programming stopped because the project changed after this bitstream was built. Build it again first.")
        }

        let allowedRoot = releaseRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let artifactURL = artifact.url.standardizedFileURL.resolvingSymlinksInPath()
        guard artifactURL.path.hasPrefix(allowedRoot), artifactURL.lastPathComponent == "design.rbf" else {
            throw FPGAStudioError.unsafePath(artifact.url.path)
        }
        let data = try Data(contentsOf: artifactURL, options: [.mappedIfSafe])
        guard (minimumBitstreamBytes...maximumBitstreamBytes).contains(data.count), data.count == artifact.byteCount else {
            throw FPGAStudioError.unsupported("Programming stopped because the bitstream size is invalid or changed after the safety check.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw FPGAStudioError.unsupported("Programming stopped because the bitstream changed after the safety check. Build it again first.")
        }
        return data
    }

    /// Parses a hex IDCODE string (with or without "0x" prefix, any width) into
    /// a canonical zero-padded lowercase form like "0x02b020dd".  Returns nil
    /// when the string is not a valid 32-bit hex value.
    static func canonicalIDCode(_ value: String) -> String? {
        var hex = value.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, let numeric = UInt32(hex, radix: 16) else { return nil }
        return String(format: "0x%08x", numeric)
    }
}
