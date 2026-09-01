import Foundation

public enum VCDRadix: String, CaseIterable, Sendable {
    case binary
    case hexadecimal
    case unsigned
    case signed
}

public struct VCDChange: Hashable, Sendable {
    public var time: UInt64
    public var value: String

    public init(time: UInt64, value: String) {
        self.time = time
        self.value = value
    }
}

public struct VCDSignal: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hierarchy: String
    public var width: Int
    public var type: String
    public var changes: [VCDChange]

    public init(id: String, name: String, hierarchy: String, width: Int, type: String, changes: [VCDChange] = []) {
        self.id = id
        self.name = name
        self.hierarchy = hierarchy
        self.width = width
        self.type = type
        self.changes = changes
    }

    public var qualifiedName: String {
        hierarchy.isEmpty ? name : "\(hierarchy).\(name)"
    }

    public func value(at time: UInt64) -> String? {
        guard !changes.isEmpty else { return nil }
        var low = 0
        var high = changes.count
        while low < high {
            let middle = (low + high) / 2
            if changes[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : changes[low - 1].value
    }

    public func formatted(_ value: String, radix: VCDRadix) -> String {
        guard !value.contains(where: { "xXzZ".contains($0) }) else { return value.lowercased() }
        switch radix {
        case .binary:
            return value
        case .hexadecimal:
            guard let number = UInt64(value, radix: 2) else { return value }
            return "0x" + String(number, radix: 16, uppercase: true)
        case .unsigned:
            return UInt64(value, radix: 2).map(String.init) ?? value
        case .signed:
            guard width > 0, width <= 64, let raw = UInt64(value, radix: 2) else { return value }
            if width == 64 { return String(Int64(bitPattern: raw)) }
            let signBit = UInt64(1) << UInt64(width - 1)
            let signed = raw & signBit == 0 ? Int64(raw) : Int64(raw) - Int64(UInt64(1) << UInt64(width))
            return String(signed)
        }
    }
}

public struct VCDDocument: Hashable, Sendable {
    public var timescale: String
    public var endTime: UInt64
    public var signals: [VCDSignal]

    public init(timescale: String = "1 ns", endTime: UInt64 = 0, signals: [VCDSignal] = []) {
        self.timescale = timescale
        self.endTime = endTime
        self.signals = signals
    }
}

public enum VCDParser {
    public static func parse(url: URL) throws -> VCDDocument {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> VCDDocument {
        var scopes: [String] = []
        var timescale = "1 ns"
        var currentTime: UInt64 = 0
        var declarations: [String: VCDSignal] = [:]
        var order: [String] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("$timescale") {
                var value = line.replacingOccurrences(of: "$timescale", with: "")
                while !value.contains("$end"), index + 1 < lines.count {
                    index += 1
                    value += " " + lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                timescale = value.replacingOccurrences(of: "$end", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("$scope") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 3 { scopes.append(String(parts[2])) }
            } else if line.hasPrefix("$upscope") {
                if !scopes.isEmpty { scopes.removeLast() }
            } else if line.hasPrefix("$var") {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 6, let width = Int(parts[2]) {
                    let identifier = String(parts[3])
                    let reference = parts[4..<(parts.count - 1)].joined(separator: " ")
                    if declarations[identifier] == nil { order.append(identifier) }
                    declarations[identifier] = VCDSignal(
                        id: identifier,
                        name: reference,
                        hierarchy: scopes.joined(separator: "."),
                        width: width,
                        type: String(parts[1]),
                        changes: declarations[identifier]?.changes ?? []
                    )
                }
            } else if line.first == "#", let time = UInt64(line.dropFirst()) {
                currentTime = time
            } else if let first = line.first, "01xXzZ".contains(first) {
                let identifier = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                append(value: String(first).lowercased(), identifier: identifier, time: currentTime, to: &declarations)
            } else if firstTokenIsVector(line) {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2 {
                    let value = String(parts[0].dropFirst()).lowercased()
                    append(value: value, identifier: String(parts[1]), time: currentTime, to: &declarations)
                }
            }
            index += 1
        }

        return VCDDocument(timescale: timescale, endTime: currentTime, signals: order.compactMap { declarations[$0] })
    }

    private static func firstTokenIsVector(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == "b" || first == "B" || first == "r" || first == "R"
    }

    private static func append(value: String, identifier: String, time: UInt64, to declarations: inout [String: VCDSignal]) {
        guard var signal = declarations[identifier] else { return }
        if signal.changes.last?.value != value {
            signal.changes.append(.init(time: time, value: value))
            declarations[identifier] = signal
        }
    }
}
