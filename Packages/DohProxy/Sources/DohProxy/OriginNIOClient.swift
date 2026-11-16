#if canImport(Darwin)
import Security
#endif
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL

/// TLS client to the origin after a raw TCP (or upstream CONNECT) hop.
/// ECH config bytes are injected into BoringSSL before ClientHello.
///
/// Darwin NIOSSL defaults to `SecTrustEvaluateAsync` + `eventLoop.execute`.
/// That never runs on `EmbeddedChannel`, so ServerHello arrives and the
/// handshake stays parked. 1.8.4 used Network.framework TLS, which evaluates
/// trust on the same connection. Mirror that with a synchronous SecTrust check
/// and pump the embedded event loop so `resumeHandshake` can run.
public final class OriginNIOClient: @unchecked Sendable {
    private let context: NIOSSLContext
    private let sni: String
    private let lock = NSLock()
    private var channel: EmbeddedChannel?
    private var handler: NIOSSLClientHandler?
    private var started = false
    private var pendingApplication = Data()
    private var handshakeNotified = false
    public let echConfig: Data?
    public private(set) var echInjected = false
    public private(set) var lastError: String?

    public init(sni: String, applicationProtocols: [String], echConfig: Data?) throws {
        self.sni = sni
        self.echConfig = echConfig
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.applicationProtocols = applicationProtocols
        context = try NIOSSLContext(configuration: configuration)
        let box = HandlerBox()
        let handler = try NIOSSLClientHandler(
            context: context,
            serverHostname: sni,
            customVerificationCallback: { certificates, promise in
                let hostname = box.handler.flatMap(BoringSSLECH.echNameOverride) ?? sni
                promise.succeed(Self.evaluateTrust(certificates: certificates, hostname: hostname))
            }
        )
        box.handler = handler
        if let echConfig, !echConfig.isEmpty {
            echInjected = BoringSSLECH.inject(into: handler, echConfig: echConfig)
        }
        self.handler = handler
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

    /// The server's `retry_configs` when it rejected ECH; non-empty means the caller
    /// can swap keys and retry immediately instead of waiting for a DNS refresh.
    public var echRetryConfigs: Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let handler else { return nil }
        return BoringSSLECH.echRetryConfigs(handler)
    }

    public func start(
        socketRead: @escaping (@escaping (Data?) -> Void) -> Void,
        socketWrite: @escaping (Data, @escaping () -> Void) -> Void,
        appRead: @escaping (Data) -> Void,
        completion: @escaping (Bool) -> Void,
        onHandshake: @escaping (Bool) -> Void = { _ in },
        /// 上游 socket 被关闭 / 出错（对端 FIN、边缘回收、RST）。
        /// 握手完成之后再报错没有意义，必须显式把这个事件交给上层：
        /// 否则客户端以为隧道还活着，请求全挂在那里，日志里一条错误都没有。
        onSocketClosed: @escaping () -> Void = {}
    ) {
        lock.lock()
        if started {
            lock.unlock()
            completion(false)
            return
        }
        started = true
        guard let handler else {
            lock.unlock()
            completion(false)
            return
        }
        let channel = EmbeddedChannel(handler: handler)
        self.channel = channel
        if let address = try? SocketAddress(ipAddress: "127.0.0.1", port: 443) {
            _ = try? channel.connect(to: address).wait()
        }
        channel.embeddedEventLoop.run()
        lock.unlock()

        func notifyHandshake(_ ok: Bool, error: String? = nil) {
            lock.lock()
            if handshakeNotified {
                lock.unlock()
                return
            }
            handshakeNotified = true
            if let error {
                lastError = error
            }
            lock.unlock()
            onHandshake(ok)
        }

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

        func ingest(_ data: Data) -> Data {
            lock.lock()
            defer { lock.unlock() }
            do {
                try channel.writeInbound(ByteBuffer(bytes: data))
                channel.embeddedEventLoop.run()
                try channel.throwIfErrorCaught()
            } catch {
                lastError = String(describing: error)
                return Data()
            }
            if BoringSSLECH.isHandshakeFinished(handler), !pendingApplication.isEmpty {
                _ = try? channel.writeOutbound(ByteBuffer(bytes: pendingApplication))
                // 写完要让内嵌事件循环跑一遍，SSL 层才会把明文加密并投递到 outbound；
                // 不跑的话调用方的 `flushOutbound` 读到的永远是空，请求就发不出去。
                channel.embeddedEventLoop.run()
                pendingApplication = Data()
            }
            var plaintext = Data()
            while let buffer = try? channel.readInbound(as: ByteBuffer.self) {
                var copy = buffer
                if let bytes = copy.readBytes(length: copy.readableBytes) {
                    plaintext.append(contentsOf: bytes)
                }
            }
            return plaintext
        }

        /// 只上报一次断连，避免读循环里重复触发。
        var closedReported = false
        func reportClosed() {
            lock.lock()
            let first = !closedReported
            closedReported = true
            lock.unlock()
            guard first else { return }
            onSocketClosed()
        }

        func pumpSocket() {
            socketRead { data in
                guard let data, !data.isEmpty else {
                    notifyHandshake(false, error: self.lastError ?? "origin socket closed")
                    reportClosed()
                    return
                }
                let plaintext = ingest(data)
                if let error = self.lastError, !BoringSSLECH.isHandshakeFinished(handler) {
                    notifyHandshake(false, error: error)
                    return
                }
                if BoringSSLECH.isHandshakeFinished(handler) {
                    notifyHandshake(true)
                }
                flushOutbound {
                    if !plaintext.isEmpty { appRead(plaintext) }
                    pumpSocket()
                }
            }
        }

        completion(true)
        pumpSocket()
        flushOutbound {}
    }

    public func writeApplication(_ data: Data, socketWrite: @escaping (Data, @escaping () -> Void) -> Void) {
        lock.lock()
        if let handler, !BoringSSLECH.isHandshakeFinished(handler) {
            pendingApplication.append(data)
            lock.unlock()
            return
        }
        _ = try? channel?.writeOutbound(ByteBuffer(bytes: data))
        // 同上：不跑事件循环，SSL 层可能还没把密文投递到 outbound。
        channel?.embeddedEventLoop.run()
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

    private static func evaluateTrust(
        certificates: [NIOSSLCertificate],
        hostname: String
    ) -> NIOSSLVerificationResult {
        #if canImport(Darwin)
        let secCerts: [SecCertificate] = certificates.compactMap { certificate in
            guard let der = try? certificate.toDERBytes() else { return nil }
            return SecCertificateCreateWithData(nil, Data(der) as CFData)
        }
        guard !secCerts.isEmpty else { return .failed }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        guard SecTrustCreateWithCertificates(secCerts as CFArray, policy, &trust) == errSecSuccess,
              let trust
        else {
            return .failed
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error) ? .certificateVerified : .failed
        #else
        _ = certificates
        _ = hostname
        return .certificateVerified
        #endif
    }
}

private final class HandlerBox {
    var handler: NIOSSLClientHandler?
}
