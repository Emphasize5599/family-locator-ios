import Foundation
import Clibsodium

/// An encrypted payload exactly as Zood transmits it: `{"cipher_text": base64, "nonce": base64}`.
nonisolated struct EncryptedData: Codable, Hashable, Sendable {
    var cipherText: Data
    var nonce: Data
}

nonisolated struct KeyPair: Codable, Hashable, Sendable {
    var publicKey: Data
    var secretKey: Data
}

/// Password hashing parameters. Mirrors `io.pijun.george.sodium.HashConfig`.
nonisolated struct PasswordHashConfig: Sendable {
    enum Algorithm: String, Sendable {
        case argon2i13
        case argon2id13

        var sodiumID: Int32 {
            switch self {
            case .argon2i13: return 1
            case .argon2id13: return 2
            }
        }
    }

    var algorithm: Algorithm
    var opsLimit: UInt64
    var memLimit: UInt64

    /// What the Android client uses when creating new accounts (Argon2id, "ZoodSensitive" ops, interactive memory).
    static let signUpDefault = PasswordHashConfig(algorithm: .argon2id13, opsLimit: 30, memLimit: 67_108_864)
    static let saltLength = 16
}

nonisolated enum CryptoError: Error {
    case sodiumInitFailed
    case keyGenerationFailed
    case encryptionFailed
    case decryptionFailed
    case passwordHashFailed
}

/// Thin wrapper around the exact libsodium primitives the Android client uses (see `app/src/main/cpp/sodium.c`).
nonisolated enum Crypto {
    static let symmetricKeyLength = Int(crypto_secretbox_keybytes())

    private static let initialized: Bool = sodium_init() >= 0

    private static func ensureInitialized() throws {
        guard initialized else { throw CryptoError.sodiumInitFailed }
    }

    static func randomBytes(_ count: Int) -> Data {
        _ = initialized
        var data = Data(count: count)
        data.withUnsafeMutableBytes { randombytes_buf($0.baseAddress!, count) }
        return data
    }

    static func generateKeyPair() throws -> KeyPair {
        try ensureInitialized()
        var pub = Data(count: Int(crypto_box_publickeybytes()))
        var sec = Data(count: Int(crypto_box_secretkeybytes()))
        let result = pub.withUnsafeMutableBytes { p in
            sec.withUnsafeMutableBytes { s in
                crypto_box_keypair(p.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        guard result == 0 else { throw CryptoError.keyGenerationFailed }
        return KeyPair(publicKey: pub, secretKey: sec)
    }

    // MARK: Symmetric (crypto_secretbox)

    static func secretBox(_ message: Data, key: Data) throws -> EncryptedData {
        try ensureInitialized()
        let nonce = randomBytes(Int(crypto_secretbox_noncebytes()))
        var cipher = Data(count: message.count + Int(crypto_secretbox_macbytes()))
        let result = cipher.withUnsafeMutableBytes { c in
            message.withUnsafeBytes { m in
                nonce.withUnsafeBytes { n in
                    key.withUnsafeBytes { k in
                        crypto_secretbox_easy(c.u8, m.u8, UInt64(message.count), n.u8, k.u8)
                    }
                }
            }
        }
        guard result == 0 else { throw CryptoError.encryptionFailed }
        return EncryptedData(cipherText: cipher, nonce: nonce)
    }

    static func secretBoxOpen(_ cipherText: Data, nonce: Data, key: Data) throws -> Data {
        try ensureInitialized()
        let macBytes = Int(crypto_secretbox_macbytes())
        guard cipherText.count > macBytes,
              nonce.count == Int(crypto_secretbox_noncebytes()),
              key.count == symmetricKeyLength else { throw CryptoError.decryptionFailed }
        var message = Data(count: cipherText.count - macBytes)
        let result = message.withUnsafeMutableBytes { m in
            cipherText.withUnsafeBytes { c in
                nonce.withUnsafeBytes { n in
                    key.withUnsafeBytes { k in
                        crypto_secretbox_open_easy(m.u8, c.u8, UInt64(cipherText.count), n.u8, k.u8)
                    }
                }
            }
        }
        guard result == 0 else { throw CryptoError.decryptionFailed }
        return message
    }

    // MARK: Public key (crypto_box)

    static func box(_ message: Data, receiverPublicKey: Data, senderSecretKey: Data) throws -> EncryptedData {
        try ensureInitialized()
        let nonce = randomBytes(Int(crypto_box_noncebytes()))
        var cipher = Data(count: message.count + Int(crypto_box_macbytes()))
        let result = cipher.withUnsafeMutableBytes { c in
            message.withUnsafeBytes { m in
                nonce.withUnsafeBytes { n in
                    receiverPublicKey.withUnsafeBytes { pk in
                        senderSecretKey.withUnsafeBytes { sk in
                            crypto_box_easy(c.u8, m.u8, UInt64(message.count), n.u8, pk.u8, sk.u8)
                        }
                    }
                }
            }
        }
        guard result == 0 else { throw CryptoError.encryptionFailed }
        return EncryptedData(cipherText: cipher, nonce: nonce)
    }

    static func boxOpen(_ cipherText: Data, nonce: Data, senderPublicKey: Data, receiverSecretKey: Data) throws -> Data {
        try ensureInitialized()
        let macBytes = Int(crypto_box_macbytes())
        guard cipherText.count > macBytes,
              nonce.count == Int(crypto_box_noncebytes()),
              senderPublicKey.count == Int(crypto_box_publickeybytes()) else { throw CryptoError.decryptionFailed }
        var message = Data(count: cipherText.count - macBytes)
        let result = message.withUnsafeMutableBytes { m in
            cipherText.withUnsafeBytes { c in
                nonce.withUnsafeBytes { n in
                    senderPublicKey.withUnsafeBytes { pk in
                        receiverSecretKey.withUnsafeBytes { sk in
                            crypto_box_open_easy(m.u8, c.u8, UInt64(cipherText.count), n.u8, pk.u8, sk.u8)
                        }
                    }
                }
            }
        }
        guard result == 0 else { throw CryptoError.decryptionFailed }
        return message
    }

    // MARK: Password stretching (crypto_pwhash)

    /// Slow by design (Argon2 with ~64 MB of memory). Never call on the main actor.
    static func stretchPassword(_ password: String, salt: Data, config: PasswordHashConfig) throws -> Data {
        try ensureInitialized()
        let passwordBytes = Data(password.utf8)
        guard !passwordBytes.isEmpty, !salt.isEmpty else { throw CryptoError.passwordHashFailed }
        var key = Data(count: symmetricKeyLength)
        let result = key.withUnsafeMutableBytes { k in
            passwordBytes.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    crypto_pwhash(k.u8, UInt64(symmetricKeyLength),
                                  p.bindMemory(to: CChar.self).baseAddress!, UInt64(passwordBytes.count),
                                  s.u8, config.opsLimit, Int(config.memLimit), config.algorithm.sodiumID)
                }
            }
        }
        guard result == 0 else { throw CryptoError.passwordHashFailed }
        return key
    }
}

private extension UnsafeRawBufferPointer {
    nonisolated var u8: UnsafePointer<UInt8> { bindMemory(to: UInt8.self).baseAddress! }
}

private extension UnsafeMutableRawBufferPointer {
    nonisolated var u8: UnsafeMutablePointer<UInt8> { bindMemory(to: UInt8.self).baseAddress! }
}

nonisolated extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
