import CryptoKit
import Foundation

public struct ToolHealth: Hashable, Identifiable, Sendable {
    public var name: String
    public var executable: String
    public var expectedVersion: String
    public var resolvedURL: URL?
    public var versionOutput: String?
    public var id: String { name }
    public var isAvailable: Bool { resolvedURL != nil }
}

public struct ToolInvocation: Sendable {
    public var tool: String
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]

    public init(tool: String, executableURL: URL, arguments: [String], workingDirectory: URL, environment: [String: String] = [:]) {
        self.tool = tool
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct ToolResult: Sendable {
    public var exitCode: Int32
    public var output: String
    public var duration: TimeInterval
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let callback: (@Sendable (String) -> Void)?

    init(callback: (@Sendable (String) -> Void)?) { self.callback = callback }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
        if let text = String(data: newData, encoding: .utf8) { callback?(text) }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public actor ToolProcessService {
    private var active: [UUID: ProcessBox] = [:]

    public init() {}

    public func run(_ invocation: ToolInvocation, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ToolResult {
        let id = UUID()
        let process = Process()
        let processBox = ProcessBox(process)
        let pipe = Pipe()
        let collector = OutputCollector(callback: onOutput)
        let started = Date()

        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = Self.sanitizedEnvironment(extra: invocation.environment, executable: invocation.executableURL)
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        active[id] = processBox
        do {
            try process.run()
        } catch {
            active[id] = nil
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
            }
        } onCancel: {
            if processBox.process.isRunning { processBox.process.terminate() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
        active[id] = nil
        return ToolResult(exitCode: status, output: collector.string(), duration: Date().timeIntervalSince(started))
    }

    public func cancelAll() {
        for process in active.values where process.process.isRunning { process.process.terminate() }
    }

    private static func sanitizedEnvironment(extra: [String: String], executable: URL) -> [String: String] {
        let bin = executable.deletingLastPathComponent()
        let prefix = bin.deletingLastPathComponent()
        var result: [String: String] = [
            "PATH": bin.path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "DYLD_LIBRARY_PATH": prefix.appendingPathComponent("lib").path,
            "YOSYS_DATDIR": prefix.appendingPathComponent("share/yosys").path,
            "VERILATOR_ROOT": prefix.appendingPathComponent("share/verilator").path,
            "GHDL_PREFIX": prefix.appendingPathComponent("lib/ghdl").path
        ]
        for (key, value) in extra where !key.contains("\0") && !value.contains("\0") { result[key] = value }
        return result
    }
}

public struct ToolchainLocator: Sendable {
    public var managedRoot: URL

    public init(managedRoot: URL = ToolchainManager.defaultRoot) {
        self.managedRoot = managedRoot
    }

    public func resolve(_ executable: String) -> URL? {
        let candidates = [
            managedRoot.appendingPathComponent("current/bin/\(executable)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(executable)"),
            URL(fileURLWithPath: "/usr/local/bin/\(executable)"),
            URL(fileURLWithPath: "/usr/bin/\(executable)"),
            URL(fileURLWithPath: "/bin/\(executable)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func require(_ executable: String) throws -> URL {
        guard let url = resolve(executable) else { throw FPGAStudioError.toolMissing(executable) }
        return url
    }
}

public actor ToolchainManager {
    public static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FPGA Studio/Toolchains", isDirectory: true)

    private let root: URL
    private let processService: ToolProcessService

    public init(root: URL = defaultRoot, processService: ToolProcessService = .init()) {
        self.root = root
        self.processService = processService
    }

    public func health(manifest: ToolchainManifest) async -> [ToolHealth] {
        let locator = ToolchainLocator(managedRoot: root)
        var result: [ToolHealth] = []
        for tool in manifest.tools {
            let url = locator.resolve(tool.executable)
            var version: String?
            if let url {
                let invocation = ToolInvocation(tool: tool.name, executableURL: url, arguments: versionArguments(for: tool.executable), workingDirectory: root)
                version = try? await processService.run(invocation).output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            result.append(.init(name: tool.name, executable: tool.executable, expectedVersion: tool.version, resolvedURL: url, versionOutput: version))
        }
        return result
    }

    public func install(archive: URL, manifest: ToolchainManifest) async throws {
        let archiveData = try Data(contentsOf: archive)
        guard let expected = manifest.archiveSHA256, !expected.isEmpty,
              let encodedSignature = manifest.archiveSignature, !encodedSignature.isEmpty,
              let encodedKey = manifest.signingPublicKey, !encodedKey.isEmpty else {
            throw FPGAStudioError.unsupported("FPGA Studio refuses to install an unsigned toolchain archive. A release manifest must provide its SHA-256 digest, Ed25519 signature, and trusted public key.")
        }
        let digest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else { throw FPGAStudioError.checksumMismatch }
        guard let signature = Data(base64Encoded: encodedSignature), let keyData = Data(base64Encoded: encodedKey) else {
            throw FPGAStudioError.signatureMismatch
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(signature, for: archiveData) else { throw FPGAStudioError.signatureMismatch }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        let result = try await processService.run(.init(tool: "Toolchain Installer", executableURL: ditto, arguments: ["-x", "-k", archive.path, staging.path], workingDirectory: root))
        guard result.exitCode == 0 else { throw FPGAStudioError.commandFailed(tool: "ditto", code: result.exitCode, output: result.output) }
        guard FileManager.default.fileExists(atPath: staging.appendingPathComponent("bin").path) else {
            throw FPGAStudioError.invalidProject("Toolchain archive does not contain a bin directory.")
        }
        let destination = root.appendingPathComponent(manifest.version, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        try activate(version: manifest.version)
    }

    public func installedVersions() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "current" }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted().reversed()
    }

    public func activate(version: String) throws {
        guard !version.contains("/"), !version.contains("..") else { throw FPGAStudioError.unsafePath(version) }
        let destination = root.appendingPathComponent(version, isDirectory: true)
        guard FileManager.default.fileExists(atPath: destination.path) else { throw FPGAStudioError.invalidProject("Toolchain version \(version) is not installed.") }
        let link = root.appendingPathComponent("current")
        let pendingLink = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: pendingLink, withDestinationURL: destination)
        if FileManager.default.fileExists(atPath: link.path) { _ = try FileManager.default.replaceItemAt(link, withItemAt: pendingLink) }
        else { try FileManager.default.moveItem(at: pendingLink, to: link) }
    }

    public func installBundledBootstrapIfAvailable(manifest: ToolchainManifest) async throws -> Bool {
        guard let archive = Bundle.main.resourceURL?.appendingPathComponent("Toolchains/bootstrap.zip"),
              FileManager.default.fileExists(atPath: archive.path) else { return false }
        try await install(archive: archive, manifest: manifest)
        return true
    }

    private func versionArguments(for executable: String) -> [String] {
        executable == "iverilog" ? ["-V"] : ["--version"]
    }
}
