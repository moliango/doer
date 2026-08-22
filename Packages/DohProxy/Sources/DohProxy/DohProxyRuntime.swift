import NIOCore
import NIOHTTP2
import NIOSSL
import NIOTransportServices

/// Pulls NIO products into the library so Tuist/SPM keep the FluxDo TLS stack.
public enum DohProxyRuntime {
    public static var nioLinked: Bool { true }
    public static var http2Linked: Bool { true }
    public static var nioSSLLinked: Bool { true }
    public static var transportServicesLinked: Bool { true }
}
