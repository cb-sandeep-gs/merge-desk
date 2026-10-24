import Foundation

/// JSON that keeps object key order and number spelling, so a merged file differs from its inputs only where
/// the content changed. (`JSONSerialization` reorders keys, which would turn every merge into a rewrite.)
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The number exactly as written.
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            return left.count == right.count && zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(left), .array(right)): return left == right
        case let (.string(left), .string(right)): return left == right
        case let (.number(left), .number(right)): return Double(left) == Double(right) || left == right
        case let (.bool(left), .bool(right)): return left == right
        case (.null, .null): return true
        default: return false
        }
    }

    /// Same content regardless of key order (for comparing a merge with a human's result).
    public func isEquivalent(to other: OrderedJSON) -> Bool {
        switch (self, other) {
        case let (.object(left), .object(right)):
            guard left.count == right.count else { return false }
            let rightByKey = Dictionary(right.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            return left.allSatisfy { pair in rightByKey[pair.key].map(pair.value.isEquivalent) ?? false }
        case let (.array(left), .array(right)):
            return left.count == right.count && zip(left, right).allSatisfy { $0.isEquivalent(to: $1) }
        default:
            return self == other
        }
    }
}

// MARK: - Parsing

public enum OrderedJSONError: Error, Equatable {
    case invalid(offset: Int)
}

extension OrderedJSON {
    public init(parsing data: Data) throws {
        var parser = Parser(bytes: Array(data))
        self = try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parseDocument() throws -> OrderedJSON {
            let value = try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw OrderedJSONError.invalid(offset: index) }
            return value
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == byte else { throw OrderedJSONError.invalid(offset: index) }
            index += 1
        }

        mutating func parseValue() throws -> OrderedJSON {
            skipWhitespace()
            guard index < bytes.count else { throw OrderedJSONError.invalid(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try parseNumber()
            }
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let utf8 = Array(word.utf8)
            guard bytes.count >= index + utf8.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
                throw OrderedJSONError.invalid(offset: index)
            }
            index += utf8.count
            return value
        }

        mutating func parseNumber() throws -> OrderedJSON {
            let start = index
            let allowed = Set("+-0123456789.eE".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty, Double(text) != nil else { throw OrderedJSONError.invalid(offset: start) }
            return .number(text)
        }

        mutating func parseString() throws -> String {
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") {
                    // Let JSONSerialization decode the escapes of this one string literal.
                    let literal = Data(bytes[start..<index])
                    guard let decoded = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String else {
                        throw OrderedJSONError.invalid(offset: start)
                    }
                    return decoded
                }
            }
            throw OrderedJSONError.invalid(offset: start)
        }

        mutating func parseArray() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw OrderedJSONError.invalid(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        mutating func parseObject() throws -> OrderedJSON {
            index += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw OrderedJSONError.invalid(offset: index) }
                let key = try parseString()
                try expect(UInt8(ascii: ":"))
                pairs.append((key, try parseValue()))
                skipWhitespace()
                guard index < bytes.count else { throw OrderedJSONError.invalid(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "}"))
                return .object(pairs)
            }
        }
    }
}

// MARK: - Writing

/// How a JSON file is laid out, detected from an existing file so a merge keeps the house style.
public struct JSONStyle: Equatable, Sendable {
    public var indent: String
    /// `" : "` (Xcode asset catalogs) or `": "`.
    public var keySeparator: String
    public var trailingNewline: Bool

    public static let standard = JSONStyle(indent: "  ", keySeparator: ": ", trailingNewline: true)

    public static func detect(_ text: String) -> JSONStyle {
        var style = JSONStyle.standard
        if let indented = text.split(separator: "\n").first(where: { $0.first == " " || $0.first == "\t" }) {
            style.indent = String(indented.prefix { $0 == " " || $0 == "\t" })
        }
        style.keySeparator = text.contains("\" : ") ? " : " : ": "
        style.trailingNewline = text.hasSuffix("\n")
        return style
    }
}

extension OrderedJSON {
    public func serialized(_ style: JSONStyle) -> String {
        var output = ""
        write(into: &output, level: 0, style: style)
        return output + (style.trailingNewline ? "\n" : "")
    }

    private func write(into output: inout String, level: Int, style: JSONStyle) {
        let inner = String(repeating: style.indent, count: level + 1)
        let outer = String(repeating: style.indent, count: level)
        switch self {
        case let .object(pairs):
            guard !pairs.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (offset, pair) in pairs.enumerated() {
                output += inner + Self.quoted(pair.key) + style.keySeparator
                pair.value.write(into: &output, level: level + 1, style: style)
                output += offset < pairs.count - 1 ? ",\n" : "\n"
            }
            output += outer + "}"
        case let .array(items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += inner
                item.write(into: &output, level: level + 1, style: style)
                output += offset < items.count - 1 ? ",\n" : "\n"
            }
            output += outer + "]"
        case let .string(text): output += Self.quoted(text)
        case let .number(text): output += text
        case let .bool(value): output += value ? "true" : "false"
        case .null: output += "null"
        }
    }

    static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Three-way merge

extension OrderedJSON {
    /// Key-wise three-way merge. Nil base/ours/theirs = absent. Returns nil (absent) or the merged value; throws
    /// `JSONMergeConflict` naming the first key both sides changed differently.
    public static func merge(base: OrderedJSON?, ours: OrderedJSON?, theirs: OrderedJSON?, path: String = "$") throws -> OrderedJSON? {
        if ours == theirs { return ours }
        if base == ours { return theirs }
        if base == theirs { return ours }
        guard case let .object(oursPairs)? = ours, case let .object(theirsPairs)? = theirs else {
            throw JSONMergeConflict(path: path)
        }
        let basePairs: [(key: String, value: OrderedJSON)]
        if case let .object(pairs)? = base { basePairs = pairs } else { basePairs = [] }
        let baseByKey = Dictionary(basePairs.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let oursByKey = Dictionary(oursPairs.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        let theirsByKey = Dictionary(theirsPairs.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })

        // Key order: ours, then theirs' other keys in their order. Keys ours deleted are visited too, so a key
        // deleted on one side and changed on the other is a conflict, not a silent loss.
        let keys = oursPairs.map(\.key) + theirsPairs.map(\.key).filter { oursByKey[$0] == nil }
        var merged: [(key: String, value: OrderedJSON)] = []
        for key in keys {
            if let value = try merge(base: baseByKey[key], ours: oursByKey[key], theirs: theirsByKey[key], path: "\(path).\(key)") {
                merged.append((key, value))
            }
        }
        return .object(merged)
    }
}

public struct JSONMergeConflict: Error, Equatable {
    public let path: String
}
