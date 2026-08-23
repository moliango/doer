import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Shadowsocks AEAD 2017 (HKDF-SHA1) and SIP022 `2022-blake3-aes-256-gcm`.
public enum ShadowsocksAEAD {
    public enum Cipher: Equatable, Sendable {
        case aes128gcm
        case aes256gcm
        case chacha20ietfpoly1305

        case blake3Aes256gcm

        public init?(name: String) {
            switch name.lowercased() {
            case "aes-128-gcm": self = .aes128gcm
            case "aes-256-gcm": self = .aes256gcm
            case "chacha20-ietf-poly1305": self = .chacha20ietfpoly1305
            case "2022-blake3-aes-256-gcm": self = .blake3Aes256gcm
            default: return nil
            }
        }

        public var keyLength: Int {
            switch self {
            case .aes128gcm: return 16
            case .aes256gcm, .chacha20ietfpoly1305, .blake3Aes256gcm: return 32
            }
        }

        public var saltLength: Int { keyLength }
    }

    public static func deriveSubkey(password: String, salt: Data, cipher: Cipher) -> Data {
        if cipher == .blake3Aes256gcm {
            let psk: Data
            if let raw = Data(base64Encoded: password), raw.count == cipher.keyLength {
                psk = raw
            } else {
                psk = Data(password.utf8)
            }
            return Blake3.deriveKey(
                context: "shadowsocks 2022 session subkey",
                keyMaterial: psk + salt
            )
        }
        let psk: Data
        if let raw = Data(base64Encoded: password), raw.count == cipher.keyLength {
            psk = raw
        } else {
            psk = evpBytesToKey(password: password, keyLength: cipher.keyLength)
        }
        return hkdfSHA1(ikm: psk, salt: salt, info: Data("ss-subkey".utf8), length: cipher.keyLength)
    }

    public static func socksAddress(host: String, port: UInt16) -> Data {
        UpstreamHandshake.socks5Connect(host: host, port: port).dropFirst(3)
    }

    /// OpenSSL EVP_BytesToKey MD5, used by SS 2017 passwords.
    public static func evpBytesToKey(password: String, keyLength: Int) -> Data {
        let pass = Data(password.utf8)
        var result = Data()
        var last = Data()
        while result.count < keyLength {
            var md5 = Insecure.MD5()
            md5.update(data: last)
            md5.update(data: pass)
            last = Data(md5.finalize())
            result.append(last)
        }
        return result.prefix(keyLength)
    }

    public static func hkdfSHA1(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        var prk = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        prk.withUnsafeMutableBytes { prkBytes in
            salt.withUnsafeBytes { saltBytes in
                ikm.withUnsafeBytes { ikmBytes in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1),
                        saltBytes.baseAddress, salt.count,
                        ikmBytes.baseAddress, ikm.count,
                        prkBytes.baseAddress
                    )
                }
            }
        }
        var okm = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            var hmac = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
            let input = previous + info + Data([counter])
            hmac.withUnsafeMutableBytes { hmacBytes in
                prk.withUnsafeBytes { prkBytes in
                    input.withUnsafeBytes { inputBytes in
                        CCHmac(
                            CCHmacAlgorithm(kCCHmacAlgSHA1),
                            prkBytes.baseAddress, prk.count,
                            inputBytes.baseAddress, input.count,
                            hmacBytes.baseAddress
                        )
                    }
                }
            }
            okm.append(hmac)
            previous = hmac
            counter += 1
        }
        return okm.prefix(length)
    }
}

public final class ShadowsocksAEADSession: @unchecked Sendable {
    private let cipher: ShadowsocksAEAD.Cipher
    private let key: SymmetricKey
    private var encNonce: UInt64 = 0
    private var decNonce: UInt64 = 0
    private var decryptBuffer = Data()
    private let lock = NSLock()

    public let salt: Data

    public init(password: String, cipher: ShadowsocksAEAD.Cipher) {
        self.cipher = cipher
        var salt = Data(count: cipher.saltLength)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, cipher.saltLength, $0.baseAddress!) }
        self.salt = salt
        let subkey = ShadowsocksAEAD.deriveSubkey(password: password, salt: salt, cipher: cipher)
        self.key = SymmetricKey(data: subkey)
    }

    public func openingPrefix(host: String, port: UInt16) -> Data {
        salt + encrypt(ShadowsocksAEAD.socksAddress(host: host, port: port))
    }

    public func encrypt(_ plaintext: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var length = UInt16(plaintext.count).bigEndian
        let lengthBytes = withUnsafeBytes(of: &length) { Data($0) }
        return seal(lengthBytes) + seal(plaintext)
    }

    public func decrypt(_ ciphertext: Data) -> Data {
        lock.lock()
        decryptBuffer.append(ciphertext)
        var output = Data()
        while true {
            guard decryptBuffer.count >= 2 + 16 else { break }
            let lengthBlob = decryptBuffer.prefix(18)
            guard let lengthPlain = open(Data(lengthBlob), nonce: decNonce) else { break }
            decNonce += 1
            let length = lengthPlain.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let payloadSize = Int(length) + 16
            guard decryptBuffer.count >= 18 + payloadSize else {
                decNonce -= 1
                break
            }
            decryptBuffer.removeFirst(18)
            let payloadBlob = decryptBuffer.prefix(payloadSize)
            decryptBuffer.removeFirst(payloadSize)
            if let payload = open(Data(payloadBlob), nonce: decNonce) {
                output.append(payload)
            }
            decNonce += 1
        }
        lock.unlock()
        return output
    }

    private func seal(_ plaintext: Data) -> Data {
        let nonceData = nonceBytes(encNonce)
        encNonce += 1
        switch cipher {
        case .aes128gcm, .aes256gcm, .blake3Aes256gcm:
            let nonce = try! AES.GCM.Nonce(data: nonceData)
            let box = try! AES.GCM.seal(plaintext, using: key, nonce: nonce)
            return box.ciphertext + box.tag
        case .chacha20ietfpoly1305:
            let nonce = try! ChaChaPoly.Nonce(data: nonceData)
            let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
            return box.ciphertext + box.tag
        }
    }

    private func open(_ blob: Data, nonce: UInt64) -> Data? {
        guard blob.count >= 16 else { return nil }
        let ciphertext = blob.dropLast(16)
        let tag = blob.suffix(16)
        let nonceData = nonceBytes(nonce)
        do {
            switch cipher {
            case .aes128gcm, .aes256gcm, .blake3Aes256gcm:
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: nonceData),
                    ciphertext: ciphertext,
                    tag: tag
                )
                return try AES.GCM.open(box, using: key)
            case .chacha20ietfpoly1305:
                let box = try ChaChaPoly.SealedBox(
                    nonce: ChaChaPoly.Nonce(data: nonceData),
                    ciphertext: ciphertext,
                    tag: tag
                )
                return try ChaChaPoly.open(box, using: key)
            }
        } catch {
            return nil
        }
    }

    private func nonceBytes(_ counter: UInt64) -> Data {
        var data = Data(count: 12)
        for index in 0 ..< 8 {
            data[index] = UInt8((counter >> (8 * index)) & 0xFF)
        }
        return data
    }
}
