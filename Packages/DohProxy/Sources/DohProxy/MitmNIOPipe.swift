import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL

/// Terminates client TLS with NIOSSL (no SecureTransport). Plaintext is copied
/// to an already-established origin TLS connection.
public final class MitmNIOPipe: @unchecked Sendable {
    private let context: NIOSSLContext
    private let lock = NSLock()
    private var channel: EmbeddedChannel?
    private var started = false

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

    public var negotiatedALPN: String? { nil }

    public func start(
        clientRead: @escaping (@escaping (Data?) -> Void) -> Void,
        clientWrite: @escaping (Data, @escaping () -> Void) -> Void,
        originRead: @escaping (@escaping (Data?) -> Void) -> Void,
        originWrite: @escaping (Data, @escaping () -> Void) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock()
        if started {
            lock.unlock()
            completion(false)
            return
        }
        started = true
        let channel = EmbeddedChannel(handler: NIOSSLServerHandler(context: context))
        self.channel = channel
        lock.unlock()

        func pumpClient() {
            clientRead { data in
                guard let data, !data.isEmpty else { return }
                self.lock.lock()
                _ = try? channel.writeInbound(ByteBuffer(bytes: data))
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
                self.lock.unlock()
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
                _ = try? channel.writeOutbound(ByteBuffer(bytes: data))
                var encrypted = Data()
                while let buffer = try? channel.readOutbound(as: ByteBuffer.self) {
                    var copy = buffer
                    if let bytes = copy.readBytes(length: copy.readableBytes) {
                        encrypted.append(contentsOf: bytes)
                    }
                }
                self.lock.unlock()
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
