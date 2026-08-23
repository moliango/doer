import Foundation

/// BLAKE3, single-chunk (inputs ≤ 1024 bytes). Enough for SS 2022 session keys.
public enum Blake3 {
    public static let outputLength = 32

    public static func hash(_ data: Data) -> Data {
        chunk(data, key: iv, flags: 0)
    }

    public static func deriveKey(context: String, keyMaterial: Data) -> Data {
        let contextKey = chunk(Data(context.utf8), key: iv, flags: Flag.deriveKeyContext.rawValue)
        var key = [UInt32](repeating: 0, count: 8)
        for index in 0 ..< 8 {
            let offset = index * 4
            key[index] =
                UInt32(contextKey[offset])
                | UInt32(contextKey[offset + 1]) << 8
                | UInt32(contextKey[offset + 2]) << 16
                | UInt32(contextKey[offset + 3]) << 24
        }
        return chunk(keyMaterial, key: key, flags: Flag.deriveKeyMaterial.rawValue)
    }

    private enum Flag: UInt32 {
        case chunkStart = 1
        case chunkEnd = 2
        case root = 8
        case deriveKeyContext = 32
        case deriveKeyMaterial = 64
    }

    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]

    private static let permutation: [Int] = [
        2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8,
    ]

    private static func chunk(_ data: Data, key: [UInt32], flags: UInt32) -> Data {
        var chaining = key
        if data.isEmpty {
            return compress(
                chaining: chaining,
                block: [UInt32](repeating: 0, count: 16),
                blockLen: 0,
                flags: flags | Flag.chunkStart.rawValue | Flag.chunkEnd.rawValue | Flag.root.rawValue
            )
        }
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let blockLen = min(64, remaining)
            var block = [UInt32](repeating: 0, count: 16)
            for byteIndex in 0 ..< blockLen {
                block[byteIndex / 4] |= UInt32(data[offset + byteIndex]) << (8 * (byteIndex % 4))
            }
            let isFirst = offset == 0
            let isLast = offset + blockLen == data.count
            var blockFlags = flags
            if isFirst { blockFlags |= Flag.chunkStart.rawValue }
            if isLast { blockFlags |= Flag.chunkEnd.rawValue | Flag.root.rawValue }
            let output = compress(
                chaining: chaining,
                block: block,
                blockLen: UInt32(blockLen),
                flags: blockFlags
            )
            if isLast { return output }
            chaining = words(from: output)
            offset += blockLen
        }
        return Data()
    }

    private static func words(from data: Data) -> [UInt32] {
        (0 ..< 8).map { index in
            let offset = index * 4
            return UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }
    }

    private static func compress(
        chaining: [UInt32],
        block: [UInt32],
        blockLen: UInt32,
        flags: UInt32
    ) -> Data {
        var state = chaining + iv
        state[8] = iv[0]
        state[9] = iv[1]
        state[10] = iv[2]
        state[11] = iv[3]
        state[12] = 0
        state[13] = 0
        state[14] = blockLen
        state[15] = flags

        var message = block
        for roundIndex in 0 ..< 7 {
            round(state: &state, message: message)
            if roundIndex == 6 { break }
            var next = [UInt32](repeating: 0, count: 16)
            for index in 0 ..< 16 {
                next[index] = message[permutation[index]]
            }
            message = next
        }

        var output = Data(count: 32)
        for index in 0 ..< 8 {
            let word = state[index] ^ state[index + 8]
            let offset = index * 4
            output[offset] = UInt8(word & 0xFF)
            output[offset + 1] = UInt8((word >> 8) & 0xFF)
            output[offset + 2] = UInt8((word >> 16) & 0xFF)
            output[offset + 3] = UInt8((word >> 24) & 0xFF)
        }
        return output
    }

    private static func round(state: inout [UInt32], message: [UInt32]) {
        g(&state, 0, 4, 8, 12, message[0], message[1])
        g(&state, 1, 5, 9, 13, message[2], message[3])
        g(&state, 2, 6, 10, 14, message[4], message[5])
        g(&state, 3, 7, 11, 15, message[6], message[7])
        g(&state, 0, 5, 10, 15, message[8], message[9])
        g(&state, 1, 6, 11, 12, message[10], message[11])
        g(&state, 2, 7, 8, 13, message[12], message[13])
        g(&state, 3, 4, 9, 14, message[14], message[15])
    }

    private static func g(
        _ state: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int,
        _ mx: UInt32,
        _ my: UInt32
    ) {
        state[a] = state[a] &+ state[b] &+ mx
        state[d] = rotate(state[d] ^ state[a], 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotate(state[b] ^ state[c], 12)
        state[a] = state[a] &+ state[b] &+ my
        state[d] = rotate(state[d] ^ state[a], 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotate(state[b] ^ state[c], 7)
    }

    private static func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}
