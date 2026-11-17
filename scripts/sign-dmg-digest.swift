import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
let seed = try String(contentsOfFile: arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let publicKey = try String(contentsOfFile: arguments[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw = Data(base64Encoded: seed) else { throw CocoaError(.fileReadCorruptFile) }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
guard key.publicKey.rawRepresentation.base64EncodedString() == publicKey else { throw CocoaError(.fileReadCorruptFile) }

let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[3]))
defer { try? file.close() }
var hasher = SHA256()
while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
let message = Data(hex.utf8)
let signature = try key.signature(for: message)
guard key.publicKey.isValidSignature(signature, for: message) else { throw CocoaError(.fileWriteUnknown) }
print(signature.base64EncodedString())
