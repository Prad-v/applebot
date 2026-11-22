import Foundation
import CryptoKit
import Security
import LLMKit

/// Encrypts / decrypts `PersonalVaultPayload` with a password (AES-GCM + PBKDF2-ish via SHA256 stretch).
enum PersonalVaultCrypto {
    private static let magic = Data("ABPK".utf8)
    private static let iterations = 120_000

    static func export(_ payload: PersonalVaultPayload, password: String) throws -> Data {
        let plain = try PersonalVaultCodec.encodePayload(payload)
        let salt = randomBytes(16)
        let key = try deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else {
            throw PersonalVaultCodec.VaultError.corrupt
        }
        // magic(4) + salt(16) + sealed
        return magic + salt + combined
    }

    static func importPayload(from data: Data, password: String) throws -> PersonalVaultPayload {
        guard data.count > 4 + 16 + 28, data.prefix(4) == magic else {
            throw PersonalVaultCodec.VaultError.corrupt
        }
        let salt = data.subdata(in: 4..<20)
        let sealedData = data.subdata(in: 20..<data.count)
        let key = try deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: sealedData)
            let plain = try AES.GCM.open(box, using: key)
            return try PersonalVaultCodec.decodePayload(plain)
        } catch is PersonalVaultCodec.VaultError {
            throw PersonalVaultCodec.VaultError.corrupt
        } catch {
            throw PersonalVaultCodec.VaultError.badPassword
        }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var accumulated = Data(password.utf8) + salt
        for _ in 0..<iterations {
            accumulated = Data(SHA256.hash(data: accumulated))
        }
        return SymmetricKey(data: accumulated)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
