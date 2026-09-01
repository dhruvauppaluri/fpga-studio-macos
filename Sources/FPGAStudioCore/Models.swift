import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public enum HDLLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case verilog
    case systemVerilog
    case vhdl

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .verilog: "Verilog"
        case .systemVerilog: "SystemVerilog"
        case .vhdl: "VHDL"
        }
    }
}

public struct ProjectSource: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var language: HDLLanguage
    public var library: String?
    public var isTestbench: Bool

    public var id: String { path }

    public init(path: String, language: HDLLanguage, library: String? = nil, isTestbench: Bool = false) {
        self.path = path
        self.language = language
        self.library = library
        self.isTestbench = isTestbench
    }
}

public struct TestTarget: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var top: String
    public var sources: [String]
    public var language: HDLLanguage
    public var waveformPath: String

    public var id: String { name }

    public init(name: String, top: String, sources: [String], language: HDLLanguage, waveformPath: String = ".fpga/build/simulation/waves.vcd") {
        self.name = name
        self.top = top
        self.sources = sources
        self.language = language
        self.waveformPath = waveformPath
    }
}

public struct SynthesisOptions: Codable, Hashable, Sendable {
    public var clockMHz: Double
    public var routingSeed: Int
    public var enableBlockRAM: Bool
    public var enableLUTRAM: Bool
    public var enableDSP: Bool

    public init(clockMHz: Double = 50, routingSeed: Int = 42, enableBlockRAM: Bool = false, enableLUTRAM: Bool = false, enableDSP: Bool = false) {
        self.clockMHz = clockMHz
        self.routingSeed = routingSeed
        self.enableBlockRAM = enableBlockRAM
        self.enableLUTRAM = enableLUTRAM
        self.enableDSP = enableDSP
    }
}

public struct FPGAProject: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var top: String
    public var board: String
    public var constraints: String
    public var sources: [ProjectSource]
    public var tests: [TestTarget]
    public var synthesis: SynthesisOptions
    public var extensions: [String: JSONValue]

    public var isReadOnly: Bool { schemaVersion > Self.supportedSchemaVersion }

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        name: String,
        top: String,
        board: String = "terasic-c5g",
        constraints: String = "constraints/c5g.qsf",
        sources: [ProjectSource],
        tests: [TestTarget] = [],
        synthesis: SynthesisOptions = .init(),
        extensions: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.top = top
        self.board = board
        self.constraints = constraints
        self.sources = sources
        self.tests = tests
        self.synthesis = synthesis
        self.extensions = extensions
    }

    private static let knownKeys: Set<String> = [
        "schemaVersion", "name", "top", "board", "constraints", "sources", "tests", "synthesis"
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        schemaVersion = try container.decode(Int.self, forKey: key("schemaVersion"))
        name = try container.decode(String.self, forKey: key("name"))
        top = try container.decode(String.self, forKey: key("top"))
        board = try container.decode(String.self, forKey: key("board"))
        constraints = try container.decode(String.self, forKey: key("constraints"))
        sources = try container.decode([ProjectSource].self, forKey: key("sources"))
        tests = try container.decodeIfPresent([TestTarget].self, forKey: key("tests")) ?? []
        synthesis = try container.decodeIfPresent(SynthesisOptions.self, forKey: key("synthesis")) ?? .init()
        extensions = [:]
        for candidate in container.allKeys where !Self.knownKeys.contains(candidate.stringValue) {
            extensions[candidate.stringValue] = try container.decode(JSONValue.self, forKey: candidate)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        for (name, value) in extensions where !Self.knownKeys.contains(name) {
            try container.encode(value, forKey: key(name))
        }
        try container.encode(schemaVersion, forKey: key("schemaVersion"))
        try container.encode(name, forKey: key("name"))
        try container.encode(top, forKey: key("top"))
        try container.encode(board, forKey: key("board"))
        try container.encode(constraints, forKey: key("constraints"))
        try container.encode(sources, forKey: key("sources"))
        try container.encode(tests, forKey: key("tests"))
        try container.encode(synthesis, forKey: key("synthesis"))
    }
}

public enum PinDirection: String, Codable, CaseIterable, Sendable {
    case input
    case output
    case bidirectional
}

public struct BoardPin: Codable, Hashable, Identifiable, Sendable {
    public var signal: String
    public var packagePin: String
    public var direction: PinDirection
    public var ioStandard: String
    public var group: String
    public var description: String

    public var id: String { signal }

    public init(signal: String, packagePin: String, direction: PinDirection, ioStandard: String, group: String, description: String) {
        self.signal = signal
        self.packagePin = packagePin
        self.direction = direction
        self.ioStandard = ioStandard
        self.group = group
        self.description = description
    }
}

public struct BoardProfile: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var displayName: String
    public var vendor: String
    public var family: String
    public var device: String
    public var packageDevice: String
    public var programmerBoard: String
    public var maturity: String
    public var experimentalNotice: String
    public var pins: [BoardPin]

    public init(schemaVersion: Int, id: String, displayName: String, vendor: String, family: String, device: String, packageDevice: String, programmerBoard: String, maturity: String, experimentalNotice: String, pins: [BoardPin]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.family = family
        self.device = device
        self.packageDevice = packageDevice
        self.programmerBoard = programmerBoard
        self.maturity = maturity
        self.experimentalNotice = experimentalNotice
        self.pins = pins
    }
}

public struct ToolDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var executable: String
    public var version: String
    public var sourceRevision: String
    public var license: String
    public var requiredFor: [String]
    public var id: String { name }
}

public struct ToolchainManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var version: String
    public var architecture: String
    public var minimumMacOS: String
    public var archiveSHA256: String?
    public var archiveSignature: String?
    public var signingPublicKey: String?
    public var tools: [ToolDescriptor]
}

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case error
    case warning
    case note
}

public struct Diagnostic: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var severity: DiagnosticSeverity
    public var message: String
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var tool: String?

    public init(id: UUID = UUID(), severity: DiagnosticSeverity, message: String, file: String? = nil, line: Int? = nil, column: Int? = nil, tool: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.tool = tool
    }
}

public enum BuildStage: String, Codable, CaseIterable, Sendable {
    case idle
    case validating
    case simulating
    case synthesizing
    case routing
    case detecting
    case programmingSRAM
    case programmingFlash
    case completed
    case failed
}

public struct BuildArtifact: Codable, Hashable, Identifiable, Sendable {
    public var kind: String
    public var path: String
    public var createdAt: Date
    public var id: String { path }
}

public struct ProgrammingArtifact: Codable, Hashable, Sendable {
    public var url: URL
    public var sha256: String
    public var byteCount: Int
    public var modifiedAt: Date

    public init(url: URL, sha256: String, byteCount: Int, modifiedAt: Date) {
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct BuildOutcome: Sendable {
    public var succeeded: Bool
    public var stage: BuildStage
    public var log: String
    public var diagnostics: [Diagnostic]
    public var artifacts: [BuildArtifact]

    public init(succeeded: Bool, stage: BuildStage, log: String, diagnostics: [Diagnostic], artifacts: [BuildArtifact] = []) {
        self.succeeded = succeeded
        self.stage = stage
        self.log = log
        self.diagnostics = diagnostics
        self.artifacts = artifacts
    }
}
