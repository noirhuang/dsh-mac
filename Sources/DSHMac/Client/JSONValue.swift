import Foundation

// MARK: - 宽松 JSON 值（wire 层未知字段容忍）

/// dsh 事件负载是插件可扩展的多态 JSON；协议层用宽松值承载，
/// 业务层按键取值，未知字段自然忽略，协议演进不致崩溃。
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var intValue: Int? {
        doubleValue.map(Int.init)
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    /// 遍历数组元素
    public var arrayElements: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    /// 对象键值（无序）
    public var objectPairs: [(String, JSONValue)] {
        if case .object(let o) = self { return Array(o) }
        return []
    }

    /// 把任意解码出的 JSONValue 序列化回紧凑 JSON 字符串
    public var jsonDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
            return String(n)
        case .string(let s): return s
        case .array(let a): return "[" + a.map(\.jsonDescription).joined(separator: ",") + "]"
        case .object(let o):
            let pairs = o.sorted { $0.key < $1.key }
                .map { "\"\(escape($0.key))\":\($0.value.jsonDescription)" }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    private func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
