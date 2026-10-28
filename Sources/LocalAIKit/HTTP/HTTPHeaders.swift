import Foundation

/// An ordered, case-insensitive header list. Order is kept because a response is
/// written out in the order it was built, and duplicates are kept because HTTP
/// allows them; lookups take the first.
public struct HTTPHeaders: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public private(set) var fields: [Field] = []

    public init(_ pairs: [(String, String)] = []) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }

    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    public mutating func set(_ name: String, _ value: String) {
        fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        fields.append(Field(name: name, value: value))
    }
}

/// A header value split into its leading token and `; key=value` parameters, as
/// `Content-Type` and `Content-Disposition` both are. Parameter names are
/// lowercased; values may be quoted, with backslash escapes.
public struct HeaderValue: Sendable, Equatable {
    public var value: String
    public var parameters: [String: String]

    public static func parse(_ raw: String) -> HeaderValue {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in raw {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" && inQuotes {
                current.append(ch)
                escaped = true
            } else if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ";" && !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)

        let value = segments.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            parameters[key] = unquote(rawValue)
        }
        return HeaderValue(value: value, parameters: parameters)
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return s }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
