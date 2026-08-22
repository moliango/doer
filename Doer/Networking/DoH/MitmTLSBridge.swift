import DohProxy
import Foundation
import Network
import Security

/// FluxDo-style CONNECT MITM using NIOSSL, not SecureTransport.
nonisolated final class MitmTLSBridge: @unchecked Sendable {
    private let client: NWConnection
    private let upstream: NWConnection
    private let lock = NSLock()
    private var pendingClient = Data()
    private var pipe: MitmNIOPipe?

    init(client: NWConnection, upstream: NWConnection) {
        self.client = client
        self.upstream = upstream
    }

    func preload(_ data: Data) {
        lock.lock()
        pendingClient.append(data)
        lock.unlock()
    }

    func start(identity: SecIdentity, alpn: [String], completion: @escaping (Bool) -> Void) {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        var key: SecKey?
        SecIdentityCopyPrivateKey(identity, &key)
        guard let certificate,
              let key,
              let keyDER = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else {
            completion(false)
            return
        }
        let certDER = SecCertificateCopyData(certificate) as Data
        do {
            let pipe = try MitmNIOPipe(
                certificateDER: certDER,
                rsaPrivateKeyDER: keyDER,
                applicationProtocols: alpn
            )
            self.pipe = pipe
            pipe.start(
                clientRead: { [weak self] deliver in
                    self?.readClient(deliver)
                },
                clientWrite: { [weak self] data, done in
                    self?.send(data, on: self?.client, done: done)
                },
                originRead: { [weak self] deliver in
                    self?.upstream.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                        deliver(data)
                    }
                },
                originWrite: { [weak self] data, done in
                    self?.send(data, on: self?.upstream, done: done)
                },
                completion: completion
            )
        } catch {
            DohDebugLog.record("MITM NIOSSL failed: \(error)")
            completion(false)
        }
    }

    private func readClient(_ deliver: @escaping (Data?) -> Void) {
        lock.lock()
        if !pendingClient.isEmpty {
            let data = pendingClient
            pendingClient = Data()
            lock.unlock()
            deliver(data)
            return
        }
        lock.unlock()
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            deliver(data)
        }
    }

    private func send(_ data: Data, on connection: NWConnection?, done: @escaping () -> Void) {
        connection?.send(
            content: data,
            contentContext: NWConnection.ContentContext(identifier: "doer.doh.mitm-nio", isFinal: false),
            isComplete: false,
            completion: .contentProcessed { _ in done() }
        )
    }
}
