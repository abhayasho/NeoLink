import Foundation

/// A decoded MessagePack value. Maps keep their wire order so decoding never hashes.
enum MsgPackValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary([UInt8])
    case array([MsgPackValue])
    case map([MsgPackPair])
    case ext(Int8, [UInt8])

    var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .uint(let value): return Int(exactly: value)
        default: return nil
        }
    }
    var uint32Value: UInt32? {
        switch self {
        case .int(let value): return UInt32(exactly: value)
        case .uint(let value): return UInt32(exactly: value)
        default: return nil
        }
    }
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .binary(let bytes): return String(decoding: bytes, as: UTF8.self)
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [MsgPackValue]? { if case .array(let value) = self { return value }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    /// The value for a string key of a map, or nil.
    subscript(key: String) -> MsgPackValue? {
        guard case .map(let pairs) = self else { return nil }
        for pair in pairs where pair.key.stringValue == key { return pair.value }
        return nil
    }
}

struct MsgPackPair: Equatable, Sendable {
    var key: MsgPackValue
    var value: MsgPackValue
    init(_ key: MsgPackValue, _ value: MsgPackValue) { self.key = key; self.value = value }
}

enum MsgPackError: Error, Equatable {
    case malformed(String)
    case tooLarge
}

/// Incremental decoder. Bytes arrive in arbitrary chunks; `next()` returns one complete
/// value at a time or nil when more bytes are needed. Bounds protect against a corrupt or
/// hostile peer: nesting depth, per-container counts and total buffered bytes are limited.
struct MsgPackStream {
    static let maximumMessageBytes = 64 * 1024 * 1024
    static let maximumDepth = 64
    private var bytes: [UInt8] = []
    private var start = 0

    var bufferedByteCount: Int { bytes.count - start }

    mutating func append(_ chunk: UnsafeBufferPointer<UInt8>) throws {
        guard bufferedByteCount + chunk.count <= Self.maximumMessageBytes else { throw MsgPackError.tooLarge }
        bytes.append(contentsOf: chunk)
    }
    mutating func append(_ chunk: [UInt8]) throws {
        try chunk.withUnsafeBufferPointer { try append($0) }
    }

    /// The next complete value, or nil when the buffer holds only part of one.
    mutating func next() throws -> MsgPackValue? {
        guard start < bytes.count else { compact(); return nil }
        var reader = Reader(bytes: bytes, offset: start)
        do {
            let value = try reader.value(depth: 0)
            start = reader.offset
            if start == bytes.count { bytes.removeAll(keepingCapacity: true); start = 0 }
            else if start > 1 << 20 && start > bytes.count / 2 { compact() }
            return value
        } catch Incomplete.needMore {
            return nil
        }
    }

    private mutating func compact() {
        if start > 0 { bytes.removeSubrange(0..<start); start = 0 }
    }

    private enum Incomplete: Error { case needMore }

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int
        init(bytes: [UInt8], offset: Int) { self.bytes = bytes; self.offset = offset }

        mutating func take(_ count: Int) throws -> Int {
            guard count >= 0, offset + count <= bytes.count else { throw Incomplete.needMore }
            defer { offset += count }
            return offset
        }
        mutating func unsigned(_ width: Int) throws -> UInt64 {
            let at = try take(width)
            var result: UInt64 = 0
            for index in 0..<width { result = (result << 8) | UInt64(bytes[at + index]) }
            return result
        }
        mutating func length(_ width: Int) throws -> Int {
            let value = try unsigned(width)
            guard value <= UInt64(MsgPackStream.maximumMessageBytes) else { throw MsgPackError.tooLarge }
            return Int(value)
        }
        mutating func string(_ count: Int) throws -> MsgPackValue {
            let at = try take(count)
            return .string(String(decoding: bytes[at..<at + count], as: UTF8.self))
        }
        mutating func binary(_ count: Int) throws -> MsgPackValue {
            let at = try take(count)
            return .binary(Array(bytes[at..<at + count]))
        }
        mutating func array(_ count: Int, depth: Int) throws -> MsgPackValue {
            // A claimed count cannot exceed the bytes that could possibly follow.
            guard count <= bytes.count - offset else { throw Incomplete.needMore }
            var items: [MsgPackValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try value(depth: depth + 1)) }
            return .array(items)
        }
        mutating func map(_ count: Int, depth: Int) throws -> MsgPackValue {
            guard count <= (bytes.count - offset) / 2 else { throw Incomplete.needMore }
            var pairs: [MsgPackPair] = []
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try value(depth: depth + 1)
                pairs.append(MsgPackPair(key, try value(depth: depth + 1)))
            }
            return .map(pairs)
        }
        mutating func ext(_ count: Int) throws -> MsgPackValue {
            let kind = Int8(bitPattern: bytes[try take(1)])
            let at = try take(count)
            return .ext(kind, Array(bytes[at..<at + count]))
        }

        mutating func value(depth: Int) throws -> MsgPackValue {
            guard depth <= MsgPackStream.maximumDepth else { throw MsgPackError.malformed("nesting is too deep") }
            let tag = bytes[try take(1)]
            switch tag {
            case 0x00...0x7f: return .int(Int64(tag))
            case 0x80...0x8f: return try map(Int(tag & 0x0f), depth: depth)
            case 0x90...0x9f: return try array(Int(tag & 0x0f), depth: depth)
            case 0xa0...0xbf: return try string(Int(tag & 0x1f))
            case 0xc0: return .null
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)
            case 0xc4: return try binary(try length(1))
            case 0xc5: return try binary(try length(2))
            case 0xc6: return try binary(try length(4))
            case 0xc7: return try ext(try length(1))
            case 0xc8: return try ext(try length(2))
            case 0xc9: return try ext(try length(4))
            case 0xca: return .double(Double(Float(bitPattern: UInt32(try unsigned(4)))))
            case 0xcb: return .double(Double(bitPattern: try unsigned(8)))
            case 0xcc: return .int(Int64(try unsigned(1)))
            case 0xcd: return .int(Int64(try unsigned(2)))
            case 0xce: return .int(Int64(try unsigned(4)))
            case 0xcf:
                let value = try unsigned(8)
                return value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
            case 0xd0: return .int(Int64(Int8(bitPattern: UInt8(try unsigned(1)))))
            case 0xd1: return .int(Int64(Int16(bitPattern: UInt16(try unsigned(2)))))
            case 0xd2: return .int(Int64(Int32(bitPattern: UInt32(try unsigned(4)))))
            case 0xd3: return .int(Int64(bitPattern: try unsigned(8)))
            case 0xd4: return try ext(1)
            case 0xd5: return try ext(2)
            case 0xd6: return try ext(4)
            case 0xd7: return try ext(8)
            case 0xd8: return try ext(16)
            case 0xd9: return try string(try length(1))
            case 0xda: return try string(try length(2))
            case 0xdb: return try string(try length(4))
            case 0xdc: return try array(try length(2), depth: depth)
            case 0xdd: return try array(try length(4), depth: depth)
            case 0xde: return try map(try length(2), depth: depth)
            case 0xdf: return try map(try length(4), depth: depth)
            case 0xe0...0xff: return .int(Int64(Int8(bitPattern: tag)))
            default: throw MsgPackError.malformed("unsupported type tag \(tag)")
            }
        }
    }
}

extension MsgPackValue {
    /// Canonical (smallest) encoding. Used for requests and tests.
    func encode(into output: inout [UInt8]) {
        func big(_ value: UInt64, _ width: Int) { for shift in stride(from: (width - 1) * 8, through: 0, by: -8) { output.append(UInt8((value >> UInt64(shift)) & 0xff)) } }
        switch self {
        case .null: output.append(0xc0)
        case .bool(let value): output.append(value ? 0xc3 : 0xc2)
        case .int(let value):
            if value >= 0 {
                if value < 128 { output.append(UInt8(value)) }
                else if value <= 0xff { output.append(0xcc); big(UInt64(value), 1) }
                else if value <= 0xffff { output.append(0xcd); big(UInt64(value), 2) }
                else if value <= 0xffff_ffff { output.append(0xce); big(UInt64(value), 4) }
                else { output.append(0xcf); big(UInt64(value), 8) }
            } else {
                if value >= -32 { output.append(UInt8(bitPattern: Int8(value))) }
                else if value >= -128 { output.append(0xd0); big(UInt64(UInt8(bitPattern: Int8(value))), 1) }
                else if value >= -32768 { output.append(0xd1); big(UInt64(UInt16(bitPattern: Int16(value))), 2) }
                else if value >= -2_147_483_648 { output.append(0xd2); big(UInt64(UInt32(bitPattern: Int32(value))), 4) }
                else { output.append(0xd3); big(UInt64(bitPattern: value), 8) }
            }
        case .uint(let value): output.append(0xcf); big(value, 8)
        case .double(let value): output.append(0xcb); big(value.bitPattern, 8)
        case .string(let value):
            let utf8 = Array(value.utf8)
            if utf8.count < 32 { output.append(0xa0 | UInt8(utf8.count)) }
            else if utf8.count <= 0xff { output.append(0xd9); big(UInt64(utf8.count), 1) }
            else if utf8.count <= 0xffff { output.append(0xda); big(UInt64(utf8.count), 2) }
            else { output.append(0xdb); big(UInt64(utf8.count), 4) }
            output.append(contentsOf: utf8)
        case .binary(let bytes):
            if bytes.count <= 0xff { output.append(0xc4); big(UInt64(bytes.count), 1) }
            else if bytes.count <= 0xffff { output.append(0xc5); big(UInt64(bytes.count), 2) }
            else { output.append(0xc6); big(UInt64(bytes.count), 4) }
            output.append(contentsOf: bytes)
        case .array(let items):
            if items.count < 16 { output.append(0x90 | UInt8(items.count)) }
            else if items.count <= 0xffff { output.append(0xdc); big(UInt64(items.count), 2) }
            else { output.append(0xdd); big(UInt64(items.count), 4) }
            for item in items { item.encode(into: &output) }
        case .map(let pairs):
            if pairs.count < 16 { output.append(0x80 | UInt8(pairs.count)) }
            else if pairs.count <= 0xffff { output.append(0xde); big(UInt64(pairs.count), 2) }
            else { output.append(0xdf); big(UInt64(pairs.count), 4) }
            for pair in pairs { pair.key.encode(into: &output); pair.value.encode(into: &output) }
        case .ext(let kind, let bytes):
            switch bytes.count {
            case 1: output.append(0xd4)
            case 2: output.append(0xd5)
            case 4: output.append(0xd6)
            case 8: output.append(0xd7)
            case 16: output.append(0xd8)
            default: output.append(0xc7); big(UInt64(bytes.count), 1)
            }
            output.append(UInt8(bitPattern: kind))
            output.append(contentsOf: bytes)
        }
    }
    var encoded: [UInt8] { var output: [UInt8] = []; encode(into: &output); return output }
}
