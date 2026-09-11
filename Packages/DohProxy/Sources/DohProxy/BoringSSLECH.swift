import Darwin
import Foundation
import NIOSSL

/// Inject DNS HTTPS ECHConfigList into BoringSSL (vendored by NIOSSL).
/// Network.framework and NIOSSL's Swift API cannot set ECH; the C API can.
public enum BoringSSLECH {
    public static func configList(from echConfig: Data) -> Data {
        guard echConfig.count >= 2 else { return wrapList(echConfig) }
        let listed = Int(echConfig[0]) << 8 | Int(echConfig[1])
        if listed + 2 == echConfig.count {
            return echConfig
        }
        return wrapList(echConfig)
    }

    public static func inject(into handler: NIOSSLHandler, echConfig: Data) -> Bool {
        guard let ssl = sslPointer(from: handler) else { return false }
        let list = configList(from: echConfig)
        return setConfigList(ssl, list)
    }

    public static func echAccepted(_ handler: NIOSSLHandler) -> Bool {
        guard let ssl = sslPointer(from: handler) else { return false }
        return echAccepted(ssl)
    }

    public static func negotiatedALPN(_ handler: NIOSSLHandler) -> String? {
        guard let ssl = sslPointer(from: handler) else { return nil }
        return alpn(ssl)
    }

    public static func isHandshakeFinished(_ handler: NIOSSLHandler) -> Bool {
        guard let ssl = sslPointer(from: handler) else { return false }
        return handshakeFinished(ssl)
    }

    private static func wrapList(_ config: Data) -> Data {
        var list = Data(count: 2)
        list[0] = UInt8((config.count >> 8) & 0xFF)
        list[1] = UInt8(config.count & 0xFF)
        list.append(config)
        return list
    }

    private static func sslPointer(from handler: NIOSSLHandler) -> OpaquePointer? {
        let handlerMirror = Mirror(reflecting: handler)
        guard let connection = handlerMirror.children.first(where: { $0.label == "connection" })?.value else {
            return nil
        }
        let connectionMirror = Mirror(reflecting: connection)
        return connectionMirror.children.first(where: { $0.label == "ssl" })?.value as? OpaquePointer
    }

    private static func setConfigList(_ ssl: OpaquePointer, _ list: Data) -> Bool {
        typealias Fn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Int32
        guard let fn: Fn = symbol("CNIOBoringSSL_SSL_set1_ech_config_list") else { return false }
        return list.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return fn(ssl, base, list.count) == 1
        }
    }

    private static func echAccepted(_ ssl: OpaquePointer) -> Bool {
        typealias Fn = @convention(c) (OpaquePointer?) -> Int32
        guard let fn: Fn = symbol("CNIOBoringSSL_SSL_ech_accepted") else { return false }
        return fn(ssl) == 1
    }

    private static func handshakeFinished(_ ssl: OpaquePointer) -> Bool {
        typealias Fn = @convention(c) (OpaquePointer?) -> Int32
        guard let fn: Fn = symbol("CNIOBoringSSL_SSL_is_init_finished") else { return true }
        return fn(ssl) == 1
    }

    private static func alpn(_ ssl: OpaquePointer) -> String? {
        typealias Fn = @convention(c) (
            OpaquePointer?,
            UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
            UnsafeMutablePointer<UInt32>?
        ) -> Void
        guard let fn: Fn = symbol("CNIOBoringSSL_SSL_get0_alpn_selected") else { return nil }
        var pointer: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        fn(ssl, &pointer, &length)
        guard let pointer, length > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: Int(length)), encoding: .utf8)
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}
