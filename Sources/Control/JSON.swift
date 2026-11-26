import Foundation

/// A JSON value that is `Sendable` and `Codable`, for the control protocol (brief 008).
/// Integers are kept apart from doubles, so ids and counts come back exactly as sent.
public enum JSON: Sendable, Equatable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d.isFinite ? d : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Building

    /// Any `Encodable` as a JSON value. `encoder` defaults to sorted keys; pass
    /// `ContractJSON.encoder()` for stored records so dates keep their fractional seconds.
    public init(encoding value: some Encodable, encoder: JSONEncoder = JSON.encoder()) throws {
        self = try JSON.parse(try encoder.encode(value))
    }

    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public func data(pretty: Bool = false) -> Data {
        (try? JSON.encoder(pretty: pretty).encode(self)) ?? Data("null".utf8)
    }

    public var description: String { String(decoding: data(), as: UTF8.self) }

    // MARK: Reading

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return Int(exactly: i)
        case .double(let d): return d.rounded() == d && abs(d) < 9e15 ? Int(d) : nil
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased()) ? true : ["false", "no", "0"].contains(s.lowercased()) ? false : nil
        default: return nil
        }
    }

    public var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Decodes this value as `T` (e.g. a `ProtocolDraft` an agent sent).
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: data())
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSON {
    static func from(_ s: String?) -> JSON { s.map(JSON.string) ?? .null }
    static func from(_ i: Int?) -> JSON { i.map { .int(Int64($0)) } ?? .null }
    static func from(_ d: Double?) -> JSON { d.map(JSON.double) ?? .null }
    static func from(_ b: Bool?) -> JSON { b.map(JSON.bool) ?? .null }
    static func from(_ u: UUID?) -> JSON { u.map { .string($0.uuidString) } ?? .null }
    static func from(_ d: Date?) -> JSON {
        d.map { .string($0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))) } ?? .null
    }
}
