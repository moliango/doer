import Foundation

/// HTTP/2 MITM: parse frames and re-encode so the hop is a real HTTP/2
/// session, not an opaque TLS byte copy.
public enum H2MitmForwarder {
    public static let clientPreface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    public static func isClientPreface(_ data: Data) -> Bool {
        data.starts(with: clientPreface)
    }

    public struct Frame: Equatable, Sendable {
        public var type: UInt8
        public var flags: UInt8
        public var streamID: UInt32
        public var payload: Data

        public init(type: UInt8, flags: UInt8, streamID: UInt32, payload: Data) {
            self.type = type
            self.flags = flags
            self.streamID = streamID
            self.payload = payload
        }
    }

    public static func decodeFrames(from buffer: inout Data) -> [Frame] {
        var frames: [Frame] = []
        while buffer.count >= 9 {
            let length = Int(buffer[0]) << 16 | Int(buffer[1]) << 8 | Int(buffer[2])
            guard buffer.count >= 9 + length else { break }
            let type = buffer[3]
            let flags = buffer[4]
            let streamID =
                UInt32(buffer[5]) << 24
                | UInt32(buffer[6]) << 16
                | UInt32(buffer[7]) << 8
                | UInt32(buffer[8])
            let payload = Data(buffer.subdata(in: 9 ..< (9 + length)))
            buffer = Data(buffer.dropFirst(9 + length))
            frames.append(Frame(type: type, flags: flags, streamID: streamID & 0x7FFF_FFFF, payload: payload))
        }
        return frames
    }

    public static func encode(_ frame: Frame) -> Data {
        var data = Data(count: 9)
        let length = frame.payload.count
        data[0] = UInt8((length >> 16) & 0xFF)
        data[1] = UInt8((length >> 8) & 0xFF)
        data[2] = UInt8(length & 0xFF)
        data[3] = frame.type
        data[4] = frame.flags
        data[5] = UInt8((frame.streamID >> 24) & 0x7F)
        data[6] = UInt8((frame.streamID >> 16) & 0xFF)
        data[7] = UInt8((frame.streamID >> 8) & 0xFF)
        data[8] = UInt8(frame.streamID & 0xFF)
        data.append(frame.payload)
        return data
    }

    public final class FrameSession: @unchecked Sendable {
        private var clientBuffer = Data()
        private var originBuffer = Data()
        private var sawClientPreface = false

        public init() {}

        public func pushClient(_ data: Data, originHTTP1: Bool?) -> Data {
            _ = originHTTP1
            clientBuffer.append(contentsOf: data)
            var output = Data()
            if !sawClientPreface {
                if clientBuffer.count < 24 { return Data() }
                if clientBuffer.starts(with: H2MitmForwarder.clientPreface) {
                    sawClientPreface = true
                    clientBuffer = Data(clientBuffer.dropFirst(24))
                    output.append(H2MitmForwarder.clientPreface)
                } else {
                    sawClientPreface = true
                }
            }
            output.append(forward(&clientBuffer))
            return output
        }

        public func pushOrigin(_ data: Data, originHTTP1: Bool?) -> Data {
            _ = originHTTP1
            originBuffer.append(contentsOf: data)
            return forward(&originBuffer)
        }

        private func forward(_ buffer: inout Data) -> Data {
            let frames = H2MitmForwarder.decodeFrames(from: &buffer)
            var output = Data()
            for frame in frames {
                output.append(H2MitmForwarder.encode(frame))
            }
            return output
        }
    }
}
