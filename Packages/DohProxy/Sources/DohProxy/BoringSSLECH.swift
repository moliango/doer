import Foundation
import NIOSSL

/// Inject DNS HTTPS ECHConfigList into BoringSSL (vendored by NIOSSL).
/// Network.framework and NIOSSL's Swift API cannot set ECH; the C API can.
///
/// Link the CNIOBoringSSL symbols directly so they are not dead-stripped.
/// `dlsym` cannot see static BoringSSL and would leave a clear `SNI=linux.do`.
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

    public static func hasSSLPointer(_ handler: NIOSSLHandler) -> Bool {
        sslPointer(from: handler) != nil
    }

    public static func echAccepted(_ handler: NIOSSLHandler) -> Bool {
        guard let ssl = sslPointer(from: handler) else { return false }
        return sslECHAccepted(ssl) == 1
    }

    public static func negotiatedALPN(_ handler: NIOSSLHandler) -> String? {
        guard let ssl = sslPointer(from: handler) else { return nil }
        return alpn(ssl)
    }

    public static func isHandshakeFinished(_ handler: NIOSSLHandler) -> Bool {
        guard let ssl = sslPointer(from: handler) else { return false }
        return sslIsInitFinished(ssl) == 1
    }

    /// Public name to verify when the server rejected ECH. Empty when ECH was accepted.
    public static func echNameOverride(_ handler: NIOSSLHandler) -> String? {
        guard let ssl = sslPointer(from: handler) else { return nil }
        var pointer: UnsafePointer<CChar>?
        var length = 0
        sslGet0ECHNameOverride(ssl, &pointer, &length)
        guard let pointer, length > 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: length),
            as: UTF8.self
        )
    }

    private static func wrapList(_ config: Data) -> Data {
        var list = Data(count: 2)
        list[0] = UInt8((config.count >> 8) & 0xFF)
        list[1] = UInt8(config.count & 0xFF)
        list.append(config)
        return list
    }

    private static func sslPointer(from handler: NIOSSLHandler) -> OpaquePointer? {
        sslPointer(in: handler, depth: 0)
    }

    /// `NIOSSLClientHandler` stores `connection` on the superclass; `SSLConnection.ssl`
    /// is private. Walk `superclassMirror` and only follow `connection` / `ssl`.
    private static func sslPointer(in value: Any, depth: Int) -> OpaquePointer? {
        if depth > 8 { return nil }
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            for child in current.children {
                if child.label == "ssl", let pointer = child.value as? OpaquePointer {
                    return pointer
                }
                if child.label == "connection" || child.label == "ssl" {
                    if let pointer = sslPointer(in: child.value, depth: depth + 1) {
                        return pointer
                    }
                }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    private static func setConfigList(_ ssl: OpaquePointer, _ list: Data) -> Bool {
        list.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return sslSetECHConfigList(ssl, base, list.count) == 1
        }
    }

    private static func alpn(_ ssl: OpaquePointer) -> String? {
        var pointer: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        sslGet0ALPNSelected(ssl, &pointer, &length)
        guard let pointer, length > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: Int(length)), encoding: .utf8)
    }
}

@_silgen_name("CNIOBoringSSL_SSL_set1_ech_config_list")
private func sslSetECHConfigList(
    _ ssl: OpaquePointer?,
    _ echConfigList: UnsafePointer<UInt8>?,
    _ echConfigListLen: Int
) -> Int32

@_silgen_name("CNIOBoringSSL_SSL_ech_accepted")
private func sslECHAccepted(_ ssl: OpaquePointer?) -> Int32

@_silgen_name("CNIOBoringSSL_SSL_is_init_finished")
private func sslIsInitFinished(_ ssl: OpaquePointer?) -> Int32

@_silgen_name("CNIOBoringSSL_SSL_get0_alpn_selected")
private func sslGet0ALPNSelected(
    _ ssl: OpaquePointer?,
    _ out: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
    _ outLen: UnsafeMutablePointer<UInt32>?
)

@_silgen_name("CNIOBoringSSL_SSL_get0_ech_name_override")
private func sslGet0ECHNameOverride(
    _ ssl: OpaquePointer?,
    _ outName: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
    _ outNameLen: UnsafeMutablePointer<Int>?
)
