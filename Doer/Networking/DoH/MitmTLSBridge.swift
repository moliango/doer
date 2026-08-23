import DohProxy
import Foundation
import Network

/// FluxDo-style CONNECT MITM using NIOSSL, not SecureTransport.
nonisolated final class MitmTLSBridge: @unchecked Sendable {
    private let client: NWConnection
    private let upstream: NWConnection
    private let lock = NSLock()
    private var pendingClient = Data()
    private var pipe: MitmNIOPipe?
    private var originTLS: OriginNIOClient?
    private var originPlaintext = Data()
    private var originWaiters: [(Data?) -> Void] = []
    private var h2Session: H2MitmForwarder.FrameSession?
    var wrapUpstreamWrite: ((Data) -> Data)?
    var wrapUpstreamRead: ((Data) -> Data)?

    init(client: NWConnection, upstream: NWConnection) {
        self.client = client
        self.upstream = upstream
    }

    func preload(_ data: Data) {
        lock.lock()
        pendingClient.append(data)
        lock.unlock()
    }

    func start(
        certificateDER: Data,
        rsaPrivateKeyDER: Data,
        alpn: [String],
        originNeedsTLS: Bool,
        sni: String,
        echConfig: Data?,
        completion: @escaping (Bool) -> Void
    ) {
        do {
            let pipe = try MitmNIOPipe(
                certificateDER: certificateDER,
                rsaPrivateKeyDER: rsaPrivateKeyDER,
                applicationProtocols: alpn
            )
            self.pipe = pipe
            if alpn.contains("h2") {
                h2Session = H2MitmForwarder.FrameSession()
            }
            if originNeedsTLS {
                let origin = try OriginNIOClient(sni: sni, applicationProtocols: alpn, echConfig: echConfig)
                self.originTLS = origin
                if let echConfig, !echConfig.isEmpty {
                    DohDebugLog.record(
                        origin.echInjected
                            ? "ECH injected for \(sni) (\(echConfig.count) bytes)"
                            : "ECH inject failed for \(sni); clear SNI"
                    )
                }
                origin.start(
                    socketRead: { [weak self] deliver in
                        self?.upstream.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                            guard let self else { return }
                            deliver(data.flatMap { self.wrapUpstreamRead?($0) ?? $0 })
                        }
                    },
                    socketWrite: { [weak self] data, done in
                        guard let self else { return }
                        self.send(self.wrapUpstreamWrite?(data) ?? data, on: self.upstream, done: done)
                    },
                    appRead: { [weak self] plaintext in
                        guard let self else { return }
                        let rewritten = self.rewriteOrigin(plaintext)
                        guard !rewritten.isEmpty else { return }
                        self.lock.lock()
                        if !self.originWaiters.isEmpty {
                            let waiter = self.originWaiters.removeFirst()
                            self.lock.unlock()
                            waiter(rewritten)
                        } else {
                            self.originPlaintext.append(rewritten)
                            self.lock.unlock()
                        }
                    },
                    completion: { _ in }
                )
            }
            pipe.start(
                clientRead: { [weak self] deliver in
                    self?.readClient(deliver)
                },
                clientWrite: { [weak self] data, done in
                    self?.send(data, on: self?.client, done: done)
                },
                originRead: { [weak self] deliver in
                    guard let self else { return }
                    if originNeedsTLS {
                        self.lock.lock()
                        if !self.originPlaintext.isEmpty {
                            let data = self.originPlaintext
                            self.originPlaintext = Data()
                            self.lock.unlock()
                            deliver(data)
                            return
                        }
                        self.originWaiters.append(deliver)
                        self.lock.unlock()
                    } else {
                        self.upstream.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                            deliver(data.flatMap { self.wrapUpstreamRead?($0) ?? $0 })
                        }
                    }
                },
                originWrite: { [weak self] data, done in
                    guard let self else { return }
                    let outbound = self.rewriteClient(data)
                    guard !outbound.isEmpty else {
                        done()
                        return
                    }
                    if originNeedsTLS {
                        self.originTLS?.writeApplication(outbound) { payload, finished in
                            self.send(self.wrapUpstreamWrite?(payload) ?? payload, on: self.upstream, done: finished)
                        }
                        done()
                    } else {
                        self.send(self.wrapUpstreamWrite?(outbound) ?? outbound, on: self.upstream, done: done)
                    }
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

    private func rewriteClient(_ data: Data) -> Data {
        guard let h2Session else { return data }
        let originHTTP1 = originTLS?.negotiatedALPN.map { $0 == "http/1.1" }
        return h2Session.pushClient(data, originHTTP1: originHTTP1)
    }

    private func rewriteOrigin(_ data: Data) -> Data {
        guard let h2Session else { return data }
        let originHTTP1 = originTLS?.negotiatedALPN.map { $0 == "http/1.1" }
        return h2Session.pushOrigin(data, originHTTP1: originHTTP1)
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
