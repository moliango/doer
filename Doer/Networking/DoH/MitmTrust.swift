import Alamofire
import Foundation
import ObjectiveC
import Security
import WebKit

nonisolated struct MitmTrustEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws {
        if MitmCertificateAuthority.shared.evaluate(trust, host: host) {
            return
        }
        try DefaultTrustEvaluator().evaluate(trust, forHost: host)
    }
}

nonisolated final class AnyHostMitmTrustManager: ServerTrustManager {
    nonisolated init() {
        super.init(allHostsMustBeEvaluated: true, evaluators: [:])
    }

    nonisolated override func serverTrustEvaluator(forHost host: String) throws -> (any ServerTrustEvaluating)? {
        MitmTrustEvaluator()
    }
}

enum FluxDoMitmTrustManager {
    static func make() -> ServerTrustManager {
        AnyHostMitmTrustManager()
    }
}

enum MitmTrust {
    private static let lock = NSLock()
    private static var hooked = false

    static func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              MitmCertificateAuthority.shared.evaluate(trust, host: challenge.protectionSpace.host)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func installWKWebViewHook() {
        lock.lock()
        defer { lock.unlock() }
        guard !hooked else { return }
        hooked = true
        guard let original = class_getInstanceMethod(WKWebView.self, #selector(setter: WKWebView.navigationDelegate)),
              let replacement = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.doer_setMitmNavigationDelegate(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

private final class MitmNavigationDelegateBox: NSObject, WKNavigationDelegate {
    weak var original: WKNavigationDelegate?

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if UserDefaults.standard.bool(forKey: "dohEnabled") {
            MitmTrust.handle(challenge, completionHandler: completionHandler)
            return
        }
        original?.webView?(webView, didReceive: challenge, completionHandler: completionHandler)
            ?? completionHandler(.performDefaultHandling, nil)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

private var mitmBoxKey: UInt8 = 0

private extension WKWebView {
    @objc func doer_setMitmNavigationDelegate(_ delegate: WKNavigationDelegate?) {
        let box = MitmNavigationDelegateBox()
        box.original = delegate
        objc_setAssociatedObject(self, &mitmBoxKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        doer_setMitmNavigationDelegate(box)
    }
}
