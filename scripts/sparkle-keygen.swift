// Keychain-free Sparkle EdDSA key tool (Ed25519 via CryptoKit).
//
//   swift scripts/sparkle-keygen.swift generate <out-file>
//       Writes two lines to <out-file> (mode 600): base64 public key, base64 private key
//       (the 32-byte Ed25519 seed, the format Sparkle's `generate_keys -x` exports and
//       `sign_update --ed-key-file` reads). Nothing secret is printed.
//
//   swift scripts/sparkle-keygen.swift verify <public-key-b64> <file> <signature-b64>
//       Exits 0 if <signature> is a valid EdDSA signature of <file> under <public-key>.
import CryptoKit
import Foundation

let args = CommandLine.arguments
func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

switch args.count > 1 ? args[1] : "" {
case "generate" where args.count == 3:
    let key = Curve25519.Signing.PrivateKey()
    let contents = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
        + key.rawRepresentation.base64EncodedString() + "\n"
    let url = URL(fileURLWithPath: args[2])
    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    try! contents.write(to: url, atomically: false, encoding: .utf8)

case "verify" where args.count == 5:
    guard let pub = Data(base64Encoded: args[2]), let sig = Data(base64Encoded: args[4]),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
        let data = FileManager.default.contents(atPath: args[3])
    else { die("verify: bad input") }
    exit(key.isValidSignature(sig, for: data) ? 0 : 1)

default:
    die("usage: sparkle-keygen.swift generate <out> | verify <pub-b64> <file> <sig-b64>")
}
