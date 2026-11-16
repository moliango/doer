import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL

/// Terminates client TLS with NIOSSL (no SecureTransport). Plaintext is copied
/// to an already-established origin TLS connection.
public final class MitmNIOPipe: @unchecked Sendable {
    /// 调试日志出口（由宿主接到自己的日志系统）。握手卡住时，
    /// 「客户端密文进来了没 / 服务端有没有吐出去 / SSL 层报了什么」只能靠它分辨。
    public static var log: ((String) -> Void)?

    private let context: NIOSSLContext
    private let lock = NSLock()
    private var channel: EmbeddedChannel?
    private var handler: NIOSSLServerHandler?
    private var started = false
    private var loggedIn = 0
    private var loggedOut = 0

    public init(certificateDER: Data, rsaPrivateKeyDER: Data, applicationProtocols: [String]) throws {
        let certificate = try NIOSSLCertificate(bytes: [UInt8](certificateDER), format: .der)
        let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](rsaPrivateKeyDER), format: .der)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        configuration.applicationProtocols = applicationProtocols
        context = try NIOSSLContext(configuration: configuration)
    }

    public var negotiatedALPN: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handler else { return nil }
        return BoringSSLECH.negotiatedALPN(handler)
    }

    public func start(
        clientRead: @escaping (@escaping (Data?) -> Void) -> Void,
        clientWrite: @escaping (Data, @escaping () -> Void) -> Void,
        originRead: @escaping (@escaping (Data?) -> Void) -> Void,
        originWrite: @escaping (Data, @escaping () -> Void) -> Void,
        completion: @escaping (Bool) -> Void,
        /// 客户端那头关了（URLSession 回收连接）。上层据此收掉源站 socket，
        /// 不然每换一次连接就漏一个到 CF 的隧道。
        onClientClosed: @escaping () -> Void = {}
    ) {
        lock.lock()
        if started {
            lock.unlock()
            completion(false)
            return
        }
        started = true
        let handler = NIOSSLServerHandler(context: context)
        self.handler = handler
        let channel = EmbeddedChannel(handler: handler)
        self.channel = channel
        // 服务端 TLS 握手是 `channelActive` 触发的（NIOSSL 自己的集成测试也是手动
        // `fireChannelActive()` 来 kick）。`EmbeddedChannel(handler:)` 不会给后加的
        // handler 补这个事件，少了它状态永远停在 `idle`：客户端第一条 ClientHello
        // 会被判成 `readInInvalidTLSState`，连接当场关掉——表现就是隧道建好但一个
        // 字节也没回，URLSession 只能自己 RST（330/310）。
        channel.pipeline.fireChannelActive()
        channel.embeddedEventLoop.run()
        lock.unlock()

        var clientClosedReported = false

        func pumpClient() {
            clientRead { data in
                guard let data, !data.isEmpty else {
                    self.lock.lock()
                    let first = !clientClosedReported
                    clientClosedReported = true
                    self.lock.unlock()
                    if first { onClientClosed() }
                    return
                }
                self.lock.lock()
                let fill = data.count
                do {
                    try channel.writeInbound(ByteBuffer(bytes: data))
                } catch {
                    self.lock.unlock()
                    Self.log?("MITM pipe 客户端密文解析失败（\(fill)B）：\(error)")
                    return
                }
                // 关键：`NIOSSLServerHandler` 把握手收尾、`flushOutput` 都排进
                // `eventLoop.execute`。`EmbeddedChannel` 上不跑这个循环，握手就永远
                // 停在"未完成"——ServerHello 一个字节也吐不出去，客户端只能干等到自己 RST。
                // 客户端方向（`OriginNIOClient`）一直有跑，这里漏了。
                channel.embeddedEventLoop.run()
                var plaintext = Data()
                while let buffer = try? channel.readInbound(as: ByteBuffer.self) {
                    var copy = buffer
                    if let bytes = copy.readBytes(length: copy.readableBytes) {
                        plaintext.append(contentsOf: bytes)
                    }
                }
                var encrypted = Data()
                while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
                    var copy = buffer
                    if let bytes = copy.readBytes(length: copy.readableBytes) {
                        encrypted.append(contentsOf: bytes)
                    }
                }
                self.loggedIn += 1
                let seq = self.loggedIn
                self.lock.unlock()
                if seq <= 3 {
                    Self.log?("MITM pipe 客户端密文 \(fill)B -> 回客户端 \(encrypted.count)B，明文 \(plaintext.count)B")
                }
                if !encrypted.isEmpty {
                    clientWrite(encrypted) { pumpClient() }
                } else {
                    pumpClient()
                }
                if !plaintext.isEmpty {
                    originWrite(plaintext) {}
                }
            }
        }

        func pumpOrigin() {
            originRead { data in
                guard let data, !data.isEmpty else { return }
                self.lock.lock()
                let fill = data.count
                do {
                    try channel.writeOutbound(ByteBuffer(bytes: data))
                } catch {
                    self.lock.unlock()
                    Self.log?("MITM pipe 源站明文加密失败（\(fill)B）：\(error)")
                    return
                }
                channel.embeddedEventLoop.run()
                var encrypted = Data()
                while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
                    var copy = buffer
                    if let bytes = copy.readBytes(length: copy.readableBytes) {
                        encrypted.append(contentsOf: bytes)
                    }
                }
                self.loggedOut += 1
                let seq = self.loggedOut
                self.lock.unlock()
                if seq <= 3 {
                    Self.log?("MITM pipe 源站明文 \(fill)B -> 回客户端 \(encrypted.count)B")
                }
                if !encrypted.isEmpty {
                    clientWrite(encrypted) { pumpOrigin() }
                } else {
                    pumpOrigin()
                }
            }
        }

        completion(true)
        pumpClient()
        pumpOrigin()
    }
}
