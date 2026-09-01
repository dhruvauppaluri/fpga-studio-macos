import Foundation

public struct PinAssignment: Hashable, Identifiable, Sendable {
    public var signal: String
    public var packagePin: String
    public var ioStandard: String?
    public var line: Int
    public var id: String { signal }
}

public enum QSFParser {
    private static let locationPattern = #"^\s*set_location_assignment\s+(PIN_[A-Z0-9]+)\s+-to\s+(.+?)\s*$"#
    private static let standardPattern = #"^\s*set_instance_assignment\s+-name\s+IO_STANDARD\s+(?:\"([^\"]+)\"|(\S+))\s+-to\s+(.+?)\s*$"#

    public static func parse(_ text: String) -> [PinAssignment] {
        let locationRegex = try! NSRegularExpression(pattern: locationPattern)
        let standardRegex = try! NSRegularExpression(pattern: standardPattern)
        var locations: [(signal: String, pin: String, line: Int)] = []
        var standards: [String: String] = [:]

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = locationRegex.firstMatch(in: line, range: range),
               let pinRange = Range(match.range(at: 1), in: line),
               let signalRange = Range(match.range(at: 2), in: line) {
                locations.append((String(line[signalRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")), String(line[pinRange]), offset + 1))
            }
            if let match = standardRegex.firstMatch(in: line, range: range),
               let signalRange = Range(match.range(at: 3), in: line) {
                let valueRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                if let swiftValueRange = Range(valueRange, in: line) {
                    standards[String(line[signalRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = String(line[swiftValueRange])
                }
            }
        }
        return locations.map { .init(signal: $0.signal, packagePin: $0.pin, ioStandard: standards[$0.signal], line: $0.line) }
    }

    public static func validate(_ assignments: [PinAssignment], against board: BoardProfile, requiredPorts: Set<String> = [], portDirections: [String: PinDirection] = [:]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let validPins = Dictionary(uniqueKeysWithValues: board.pins.map { ($0.packagePin.uppercased(), $0) })
        var usedPins: [String: PinAssignment] = [:]
        var usedSignals: [String: PinAssignment] = [:]

        for assignment in assignments {
            let pin = assignment.packagePin.uppercased()
            if let previous = usedPins[pin], previous.signal != assignment.signal {
                diagnostics.append(.init(severity: .error, message: "\(pin) is assigned to both \(previous.signal) and \(assignment.signal).", line: assignment.line, tool: "Constraints"))
            } else { usedPins[pin] = assignment }

            if let previous = usedSignals[assignment.signal], previous.packagePin != assignment.packagePin {
                diagnostics.append(.init(severity: .error, message: "\(assignment.signal) has multiple package pins.", line: assignment.line, tool: "Constraints"))
            } else { usedSignals[assignment.signal] = assignment }

            guard let known = validPins[pin] else {
                diagnostics.append(.init(severity: .error, message: "\(pin) is not in the validated C5G package-pin profile.", line: assignment.line, tool: "Constraints"))
                continue
            }
            let baseSignal = assignment.signal.split(separator: "[").first.map(String.init) ?? assignment.signal
            if let direction = portDirections[baseSignal], direction != .bidirectional, known.direction != .bidirectional, direction != known.direction {
                diagnostics.append(.init(severity: .error, message: "\(assignment.signal) is a top-level \(direction.rawValue), but \(pin) is validated as \(known.direction.rawValue) for \(known.signal).", line: assignment.line, tool: "Constraints"))
            }
            if let standard = assignment.ioStandard, standard.caseInsensitiveCompare(known.ioStandard) != .orderedSame {
                diagnostics.append(.init(severity: .warning, message: "\(assignment.signal) uses \(standard); validated \(known.signal) uses \(known.ioStandard).", line: assignment.line, tool: "Constraints"))
            }
        }
        for port in requiredPorts where !usedSignals.keys.contains(where: { $0 == port || $0.hasPrefix(port + "[") }) {
            diagnostics.append(.init(severity: .error, message: "Top-level port \(port) has no location assignment.", tool: "Constraints"))
        }
        return diagnostics
    }
}

public enum SourcePortExtractor {
    public static func ports(in text: String, language: HDLLanguage, top: String) -> Set<String> {
        Set(portDirections(in: text, language: language, top: top).keys)
    }

    public static func portDirections(in text: String, language: HDLLanguage, top: String) -> [String: PinDirection] {
        switch language {
        case .verilog, .systemVerilog:
            let escaped = NSRegularExpression.escapedPattern(for: top)
            let pattern = #"(?s)module\s+"# + escaped + #"\s*(?:#\s*\(.*?\)\s*)?\((.*?)\)\s*;"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
                  let bodyRange = Range(match.range(at: 1), in: text) else { return [:] }
            let body = String(text[bodyRange])
            let cleaned = body.replacingOccurrences(of: #"\[[^\]]+\]"#, with: " ", options: .regularExpression)
            let tokens = cleaned.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            var lastDirection: PinDirection?
            var result: [String: PinDirection] = [:]
            for token in tokens {
                let words = token.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if words.contains("input") { lastDirection = .input }
                else if words.contains("output") { lastDirection = .output }
                else if words.contains("inout") { lastDirection = .bidirectional }
                if let rawName = words.last, let lastDirection {
                    let name = rawName.replacingOccurrences(of: #"[^A-Za-z0-9_$]"#, with: "", options: .regularExpression)
                    if !name.isEmpty { result[name] = lastDirection }
                }
            }
            return result
        case .vhdl:
            let escaped = NSRegularExpression.escapedPattern(for: top)
            let pattern = #"(?is)entity\s+"# + escaped + #"\s+is.*?port\s*\((.*?)\)\s*;?\s*end"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
                  let bodyRange = Range(match.range(at: 1), in: text) else { return [:] }
            var result: [String: PinDirection] = [:]
            for declaration in String(text[bodyRange]).components(separatedBy: ";") {
                let sides = declaration.split(separator: ":", maxSplits: 1).map(String.init)
                guard sides.count == 2 else { continue }
                let lower = sides[1].lowercased()
                let direction: PinDirection = lower.range(of: #"\binout\b"#, options: .regularExpression) != nil ? .bidirectional : lower.range(of: #"\bout\b"#, options: .regularExpression) != nil ? .output : .input
                for name in sides[0].split(separator: ",") {
                    result[name.trimmingCharacters(in: .whitespacesAndNewlines)] = direction
                }
            }
            return result
        }
    }
}

public enum ProjectValidator {
    public static func validate(project: FPGAProject, root: URL, board: BoardProfile) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        if project.schemaVersion > FPGAProject.supportedSchemaVersion {
            diagnostics.append(.init(severity: .warning, message: "Schema \(project.schemaVersion) is newer than this app supports. The project is read-only.", tool: "Project"))
        }
        if project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(.init(severity: .error, message: "Project name is empty.", tool: "Project"))
        }
        let safeName = project.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$"#, options: .regularExpression) != nil
        if !safeName {
            diagnostics.append(.init(severity: .error, message: "Project name must be 1–80 filename-safe characters and cannot contain path separators.", tool: "Project"))
        }
        if project.top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(.init(severity: .error, message: "Top-level module or entity is empty.", tool: "Project"))
        }
        if project.board != board.id {
            diagnostics.append(.init(severity: .error, message: "Board profile \(project.board) is not installed.", tool: "Project"))
        }
        if project.sources.filter({ !$0.isTestbench }).isEmpty {
            diagnostics.append(.init(severity: .error, message: "No synthesizable sources are configured.", tool: "Project"))
        }

        var requiredPorts = Set<String>()
        var portDirections: [String: PinDirection] = [:]
        for source in project.sources {
            do {
                let url = try ProjectStore.resolve(source.path, under: root)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    diagnostics.append(.init(severity: .error, message: "Source file does not exist.", file: source.path, tool: "Project"))
                    continue
                }
                if !source.isTestbench, let text = try? String(contentsOf: url, encoding: .utf8) {
                    requiredPorts.formUnion(SourcePortExtractor.ports(in: text, language: source.language, top: project.top))
                    portDirections.merge(SourcePortExtractor.portDirections(in: text, language: source.language, top: project.top)) { existing, _ in existing }
                }
            } catch {
                diagnostics.append(.init(severity: .error, message: error.localizedDescription, file: source.path, tool: "Project"))
            }
        }

        do {
            let constraintsURL = try ProjectStore.resolve(project.constraints, under: root)
            let text = try String(contentsOf: constraintsURL, encoding: .utf8)
            diagnostics.append(contentsOf: QSFParser.validate(QSFParser.parse(text), against: board, requiredPorts: requiredPorts, portDirections: portDirections))
        } catch {
            diagnostics.append(.init(severity: .error, message: "Cannot read constraints: \(error.localizedDescription)", file: project.constraints, tool: "Constraints"))
        }

        if project.synthesis.enableBlockRAM || project.synthesis.enableLUTRAM || project.synthesis.enableDSP {
            diagnostics.append(.init(severity: .warning, message: "Experimental Cyclone V hard-block inference is enabled.", tool: "Synthesis"))
        }
        return diagnostics
    }
}

public enum DiagnosticParser {
    private static let filePattern = #"^(.+?):(\d+)(?::(\d+))?:\s*(?:(error|warning|note)[:\s])?\s*(.+)$"#

    public static func parse(_ output: String, tool: String) -> [Diagnostic] {
        let regex = try! NSRegularExpression(pattern: filePattern, options: [.caseInsensitive])
        return output.components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let fileRange = Range(match.range(at: 1), in: line),
                  let lineRange = Range(match.range(at: 2), in: line),
                  let messageRange = Range(match.range(at: 5), in: line) else { return nil }
            let severity: DiagnosticSeverity
            if match.range(at: 4).location != NSNotFound,
               let severityRange = Range(match.range(at: 4), in: line) {
                severity = DiagnosticSeverity(rawValue: String(line[severityRange]).lowercased()) ?? .error
            } else {
                severity = line.localizedCaseInsensitiveContains("warning") ? .warning : .error
            }
            let column: Int?
            if match.range(at: 3).location != NSNotFound, let columnRange = Range(match.range(at: 3), in: line) {
                column = Int(line[columnRange])
            } else { column = nil }
            return Diagnostic(severity: severity, message: String(line[messageRange]), file: String(line[fileRange]), line: Int(line[lineRange]), column: column, tool: tool)
        }
    }
}
