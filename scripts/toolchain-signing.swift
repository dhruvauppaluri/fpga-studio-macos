#!/usr/bin/env swift
import CryptoKit
import Foundation

enum SigningError: LocalizedError {
    case usage
    case invalidKey
    case invalidManifest
    case checksumMismatch
    case signatureMismatch
    case refusingToOverwrite(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: toolchain-signing.swift generate <private-key-file> | sign <archive> <template-manifest> <output-manifest> <private-key-file> | verify <archive> <manifest>"
        case .invalidKey: return "The signing key is not a base64-encoded 32-byte Curve25519 private key."
        case .invalidManifest: return "The toolchain manifest is missing valid signing metadata."
        case .checksumMismatch: return "The toolchain archive SHA-256 does not match the manifest."
        case .signatureMismatch: return "The toolchain archive signature does not match the manifest."
        case .refusingToOverwrite(let path): return "Refusing to overwrite existing signing key at \(path)."
        }
    }
}

func archiveDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func loadObject(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw SigningError.invalidManifest
    }
    return object
}

func writeObject(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: url, options: .atomic)
}

func privateKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
    let encoded = String(decoding: try Data(contentsOf: url), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: encoded), raw.count == 32 else { throw SigningError.invalidKey }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func generateKey(at url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw SigningError.refusingToOverwrite(url.path)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: url, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    print("Generated private signing key at \(url.path). Keep it secret and backed up; never commit it.")
    print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
}

func sign(archive: URL, template: URL, output: URL, keyURL: URL) throws {
    let data = try Data(contentsOf: archive)
    let key = try privateKey(at: keyURL)
    var manifest = try loadObject(template)
    manifest["archiveSHA256"] = archiveDigest(data)
    manifest["archiveSignature"] = try key.signature(for: data).base64EncodedString()
    manifest["signingPublicKey"] = key.publicKey.rawRepresentation.base64EncodedString()
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeObject(manifest, to: output)
    print("Signed \(archive.lastPathComponent) and wrote \(output.path)")
}

func verify(archive: URL, manifestURL: URL) throws {
    let data = try Data(contentsOf: archive)
    let manifest = try loadObject(manifestURL)
    guard let expectedDigest = manifest["archiveSHA256"] as? String,
          let signatureText = manifest["archiveSignature"] as? String,
          let publicKeyText = manifest["signingPublicKey"] as? String,
          let signature = Data(base64Encoded: signatureText),
          let publicKeyData = Data(base64Encoded: publicKeyText),
          publicKeyData.count == 32 else { throw SigningError.invalidManifest }
    guard archiveDigest(data).caseInsensitiveCompare(expectedDigest) == .orderedSame else {
        throw SigningError.checksumMismatch
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: data) else { throw SigningError.signatureMismatch }
    print("Verified signed toolchain archive \(archive.lastPathComponent)")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "generate" where arguments.count == 2:
        try generateKey(at: URL(fileURLWithPath: arguments[1]))
    case "sign" where arguments.count == 5:
        try sign(
            archive: URL(fileURLWithPath: arguments[1]),
            template: URL(fileURLWithPath: arguments[2]),
            output: URL(fileURLWithPath: arguments[3]),
            keyURL: URL(fileURLWithPath: arguments[4])
        )
    case "verify" where arguments.count == 3:
        try verify(archive: URL(fileURLWithPath: arguments[1]), manifestURL: URL(fileURLWithPath: arguments[2]))
    default:
        throw SigningError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(2)
}
