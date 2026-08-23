import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL

/// TLS client to the origin after a raw TCP (or upstream CONNECT) hop.
/// ECH config bytes are injected into BoringSSL before ClientHello.
public final class OriginNIOClient: @unchecked Sendable {
    private let context: NIOSSLContext
    private let sni: String
    private let lock = NSLock()
    private var channel: EmbeddedChannel?
    private var handler: NIOSSLClientHandler?
    private var started = false
    private var pendingApplication = Data()
    public let echConfig: Data?
    public private(set) var echInjected = false

    public init(sni: String, applicationProtocols: [String], echConfig: Data?) throws {
        self.sni = sni
        self.echConfig = echConfig
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.applicationProtocols = applicationProtocols
        context = try NIOSSLContext(configuration: configuration)
    }

    public var negotiatedALPN: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handler else { return nil }
        return BoringSSLECH.negotiatedALPN(handler)
    }

    public var echAccepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handler else { return false }
        return BoringSSLECH.echAccepted(handler)
    }

    public func start(
        socketRead: @escaping (@escaping (Data?) -> Void) -> Void,
        socketWrite: @escaping (Data, @escaping () -> Void) -> Void,
        appRead: @escaping (Data) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock()
        if started {
            lock.unlock()
            completion(false)
            return
        }
        started = true
        let handler = try? NIOSSLClientHandler(context: context, serverHostname: sni)
        guard let handler else {
            lock.unlock()
            completion(false)
            return
        }
        if let echConfig, !echConfig.isEmpty {
            echInjected = BoringSSLECH.inject(into: handler, echConfig: echConfig)
        }
        self.handler = handler
        let channel = EmbeddedChannel(handler: handler)
        self.channel = channel
        if let address = try? SocketAddress(ipAddress: "127.0.0.1", port: 443) {
            _ = try? channel.connect(to: address).wait()
        }
        lock.unlock()

        func flushOutbound(_ done: @escaping () -> Void) {
            lock.lock()
            var encrypted = Data()
            while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
                var copy = buffer
                if let bytes = copy.readBytes(length: copy.readableBytes) {
                    encrypted.append(contentsOf: bytes)
                }
            }
            lock.unlock()
            if encrypted.isEmpty {
                done()
            } else {
                socketWrite(encrypted, done)
            }
        }

        func pumpSocket() {
            socketRead { data in
                guard let data, !data.isEmpty else { return }
                self.lock.lock()
                _ = try? channel.writeInbound(ByteBuffer(bytes: data))
                if let handler = self.handler,
                   BoringSSLECH.isHandshakeFinished(handler),
                   !self.pendingApplication.isEmpty
                {
                    _ = try? channel.writeOutbound(ByteBuffer(bytes: self.pendingApplication))
                    self.pendingApplication = Data()
                }
                var plaintext = Data()
                while let buffer = try? channel.readInbound(as: ByteBuffer.self) {
                    var copy = buffer
                    if let bytes = copy.readBytes(length: copy.readableBytes) {
                        plaintext.append(contentsOf: bytes)
                    }
                }
                self.lock.unlock()
                flushOutbound {
                    if !plaintext.isEmpty { appRead(plaintext) }
                    pumpSocket()
                }
            }
        }

        completion(true)
        flushOutbound {
            pumpSocket()
        }
    }

    public func writeApplication(_ data: Data, socketWrite: @escaping (Data, @escaping () -> Void) -> Void) {
        lock.lock()
        if let handler, !BoringSSLECH.isHandshakeFinished(handler) {
            pendingApplication.append(data)
            lock.unlock()
            return
        }
        _ = try? channel?.writeOutbound(ByteBuffer(bytes: data))
        var encrypted = Data()
        while let buffer = try? channel?.readOutbound(as: ByteBuffer.self) {
            var copy = buffer
            if let bytes = copy.readBytes(length: copy.readableBytes) {
                encrypted.append(contentsOf: bytes)
            }
        }
        lock.unlock()
        if !encrypted.isEmpty {
            socketWrite(encrypted) {}
        }
    }
}
