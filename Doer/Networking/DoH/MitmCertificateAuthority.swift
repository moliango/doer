import Foundation
import Security

/// Per-device MITM CA, matching FluxDo `PerDeviceCertService`.
/// Leaf certificates are issued for CONNECT targets so URLSession / WKWebView
/// terminate TLS at the local proxy; outbound TLS is native to the DoH IP.
nonisolated final class MitmCertificateAuthority: @unchecked Sendable {
    static let shared = MitmCertificateAuthority()

    private let lock = NSLock()
    private var caCertificate: SecCertificate?
    private var caKey: SecKey?
    private var leafKey: SecKey?
    private var leafCache: [String: SecIdentity] = [:]
    private var leafDERCache: [String: (certificate: Data, rsaPrivateKey: Data)] = [:]

    private init() {}

    var certificate: SecCertificate? {
        lock.lock()
        defer { lock.unlock() }
        ensureCA()
        return caCertificate
    }

    func derMaterial(for host: String) -> (certificate: Data, rsaPrivateKey: Data)? {
        let normalized = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        ensureCA()
        if let cached = leafDERCache[normalized] {
            return cached
        }
        guard let caKey, let leafKey, let leafPublic = SecKeyCopyPublicKey(leafKey) else {
            DohDebugLog.record("MITM leaf keys missing for \(normalized)")
            return nil
        }
        guard let leafData = X509Issuer.leaf(host: normalized, caKey: caKey, leafPublicKey: leafPublic) else {
            DohDebugLog.record("MITM leaf encode failed for \(normalized)")
            return nil
        }
        guard SecCertificateCreateWithData(nil, leafData as CFData) != nil else {
            DohDebugLog.record("MITM leaf DER invalid for \(normalized)")
            return nil
        }
        guard let keyDER = SecKeyCopyExternalRepresentation(leafKey, nil) as Data? else {
            DohDebugLog.record("MITM leaf key export failed for \(normalized)")
            return nil
        }
        let material = (certificate: leafData, rsaPrivateKey: keyDER)
        leafDERCache[normalized] = material
        DohDebugLog.record("MITM leaf issued for \(normalized) cert=\(leafData.count) key=\(keyDER.count)")
        return material
    }

    func identity(for host: String) -> SecIdentity? {
        let normalized = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        ensureCA()
        if let cached = leafCache[normalized] {
            return cached
        }
        guard let identity = issueLeaf(host: normalized) else { return nil }
        leafCache[normalized] = identity
        return identity
    }

    func evaluate(_ trust: SecTrust, host: String) -> Bool {
        guard let ca = certificate else { return false }
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    static func isCloudflareChallengeHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "challenges.cloudflare.com"
            || normalized.hasSuffix(".challenges.cloudflare.com")
    }

    private func ensureCA() {
        if caCertificate != nil, caKey != nil, leafKey != nil { return }
        caKey = persistentRSAKey(tag: "com.naine.doer.doh.mitm-ca")
        leafKey = persistentRSAKey(tag: "com.naine.doer.doh.mitm-leaf")
        guard let caKey, let publicKey = SecKeyCopyPublicKey(caKey) else { return }
        guard let certData = X509Issuer.selfSignedCA(privateKey: caKey, publicKey: publicKey) else { return }
        caCertificate = SecCertificateCreateWithData(nil, certData as CFData)
        DohDebugLog.record("MITM CA ready")
    }

    private func persistentRSAKey(tag: String) -> SecKey? {
        let tagData = Data(tag.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess {
            return (item as! SecKey)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }

    private func issueLeaf(host: String) -> SecIdentity? {
        guard let caKey, let leafKey, let leafPublic = SecKeyCopyPublicKey(leafKey) else {
            return nil
        }
        guard let leafData = X509Issuer.leaf(host: host, caKey: caKey, leafPublicKey: leafPublic) else {
            return nil
        }
        guard let leafCert = SecCertificateCreateWithData(nil, leafData as CFData) else { return nil }

        let label = "doer.doh.leaf.\(host)" as CFString
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: leafCert,
            kSecAttrLabel as String: label,
        ] as CFDictionary, nil)

        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchItemList as String: [leafCert],
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(identityQuery as CFDictionary, &result) == errSecSuccess {
            return (result as! SecIdentity)
        }
        let fallback: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        guard SecItemCopyMatching(fallback as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity]
        else { return nil }
        for identity in identities {
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity, &cert)
            if let cert, SecCertificateCopyData(cert) as Data == leafData {
                return identity
            }
        }
        return nil
    }
}

private enum X509Issuer {
    static func selfSignedCA(privateKey: SecKey, publicKey: SecKey) -> Data? {
        signedCertificate(
            subject: "Doer DoH MITM CA",
            host: nil,
            isCA: true,
            privateKey: privateKey,
            publicKey: publicKey,
            issuerPublicKey: publicKey
        )
    }

    static func leaf(host: String, caKey: SecKey, leafPublicKey: SecKey) -> Data? {
        signedCertificate(
            subject: host,
            issuer: "Doer DoH MITM CA",
            host: host,
            isCA: false,
            signer: caKey,
            publicKey: leafPublicKey
        )
    }

    private static func signedCertificate(
        subject: String,
        host: String?,
        isCA: Bool,
        privateKey: SecKey,
        publicKey: SecKey,
        issuerPublicKey: SecKey?
    ) -> Data? {
        signedCertificate(
            subject: subject,
            issuer: subject,
            host: host,
            isCA: isCA,
            signer: privateKey,
            publicKey: publicKey
        )
    }

    private static func signedCertificate(
        subject: String,
        issuer: String,
        host: String?,
        isCA: Bool,
        signer: SecKey,
        publicKey: SecKey
    ) -> Data? {
        guard let spki = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        let tbs = tbsCertificate(
            subject: subject,
            issuer: issuer,
            host: host,
            isCA: isCA,
            rsaPublicKey: spki
        )
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signer,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &error
        ) as Data? else { return nil }
        return derSequence([
            tbs,
            derSequence([derOID([1, 2, 840, 113549, 1, 1, 11]), Data([0x05, 0x00])]),
            derBitString(signature),
        ])
    }

    private static func tbsCertificate(
        subject: String,
        issuer: String,
        host: String?,
        isCA: Bool,
        rsaPublicKey: Data
    ) -> Data {
        let now = Date()
        let notBefore = now.addingTimeInterval(-86_400)
        let notAfter = now.addingTimeInterval(86_400 * 365 * 5)
        let subjectName = derSequence([
            derSet([derSequence([derOID([2, 5, 4, 3]), derUTF8(subject)])]),
        ])
        let issuerName = derSequence([
            derSet([derSequence([derOID([2, 5, 4, 3]), derUTF8(issuer)])]),
        ])
        var extensions: [Data] = [
            derSequence([
                derOID([2, 5, 29, 19]),
                Data([0x01, 0x01, 0xFF]),
                derOctet(derSequence(isCA ? [Data([0x01, 0x01, 0xFF])] : [])),
            ]),
        ]
        if let host {
            let san = derSequence([Data([0x82]) + derLength(host.utf8.count) + Data(host.utf8)])
            extensions.append(derSequence([
                derOID([2, 5, 29, 17]),
                derOctet(san),
            ]))
        }
        let ext = derSequence([derOID([2, 5, 29, 15]), derOctet(derBitString(Data([isCA ? 0x01 : 0x80])))])
        extensions.append(ext)
        return derSequence([
            Data([0xA0, 0x03, 0x02, 0x01, 0x02]),
            derInteger(Data([0x01])),
            derSequence([derOID([1, 2, 840, 113549, 1, 1, 11]), Data([0x05, 0x00])]),
            issuerName,
            derSequence([derUTCTime(notBefore), derUTCTime(notAfter)]),
            subjectName,
            rsaSPKI(rsaPublicKey),
            Data([0xA3]) + derLength(derSequence(extensions).count) + derSequence(extensions),
        ])
    }

    private static func rsaSPKI(_ pkcs1: Data) -> Data {
        let algo = derSequence([derOID([1, 2, 840, 113549, 1, 1, 1]), Data([0x05, 0x00])])
        return derSequence([algo, derBitString(pkcs1)])
    }

    private static func derSequence(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30]) + derLength(body.count) + body
    }

    private static func derSet(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x31]) + derLength(body.count) + body
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var value = bytes
        if let first = value.first, first & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        return Data([0x02]) + derLength(value.count) + value
    }

    private static func derOctet(_ data: Data) -> Data {
        Data([0x04]) + derLength(data.count) + data
    }

    private static func derBitString(_ data: Data) -> Data {
        Data([0x03]) + derLength(data.count + 1) + Data([0x00]) + data
    }

    private static func derUTF8(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return Data([0x0C]) + derLength(bytes.count) + bytes
    }

    private static func derOID(_ nodes: [UInt]) -> Data {
        var bytes: [UInt8] = [UInt8(nodes[0] * 40 + nodes[1])]
        for node in nodes.dropFirst(2) {
            var value = node
            var stack: [UInt8] = []
            stack.append(UInt8(value & 0x7F))
            value >>= 7
            while value > 0 {
                stack.append(UInt8((value & 0x7F) | 0x80))
                value >>= 7
            }
            bytes.append(contentsOf: stack.reversed())
        }
        let data = Data(bytes)
        return Data([0x06]) + derLength(data.count) + data
    }

    private static func derUTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let bytes = Data(formatter.string(from: date).utf8)
        return Data([0x17]) + derLength(bytes.count) + bytes
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        if length < 0x100 { return Data([0x81, UInt8(length)]) }
        return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
    }
}
