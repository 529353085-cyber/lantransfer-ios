//
//  JSONValue.swift
//  章鱼快传
//
//  任意 JSON 值容器。Swift 标准库没有 AnyCodable，而控制层信封的 payload
//  随 type 变化（20 种），需要一种类型在解码时保留原始 JSON、再按 type 二次解码。
//  与桌面 decodeMessage 的 payload:unknown 语义、Android payload:JsonElement 一一对应。
//

import Foundation

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init<T: Encodable>(encodable value: T) throws {
        let data = try ProtocolJson.encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try ProtocolJson.encoder.encode(self)
        return try ProtocolJson.decoder.decode(T.self, from: data)
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // 整数值输出为整数，避免 1 变成 1.0 影响对端解析。
            if value.rounded(.towardZero) == value, value >= -9_007_199_254_740_992, value <= 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: - 便捷访问

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
