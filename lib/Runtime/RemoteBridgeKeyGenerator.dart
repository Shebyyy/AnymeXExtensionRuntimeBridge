import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Generates an ed25519 SSH keypair (OpenSSH PEM format) for the remote
/// bridge client.
///
/// The private key is persisted to platform Secure Storage; the public
/// key is sent to the server during SSH authentication (the server uses
/// the public key fingerprint as the user identity).
class RemoteBridgeKeyGenerator {
  static const _algorithm = 'ssh-ed25519';
  static const _comment = 'anymex-remote-bridge';

  /// Generate a fresh ed25519 keypair.
  ///
  /// Returns the private key in OpenSSH PEM format, ready to be parsed
  /// by `SSHKeyPair.fromPem()` and stored in Secure Storage.
  static Future<String> generatePrivateKeyPem() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();

    // cryptography 2.9.0 API: extractPrivateKeyBytes returns List<int>,
    // and there's no extractPublicKeyBytes on SimpleKeyPair — we go via
    // extractPublicKey() then read .bytes. Both are wrapped to Uint8List
    // because _encodeOpenSshEd25519Pem requires typed byte buffers for
    // setRange() below.
    final privateKeyBytes =
        Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBytes = Uint8List.fromList(publicKey.bytes);

    return _encodeOpenSshEd25519Pem(
      privateKeyBytes: privateKeyBytes,
      publicKeyBytes: publicKeyBytes,
    );
  }

  /// Encode an ed25519 keypair as an OpenSSH private key PEM string.
  ///
  /// Format: `openssh-key-v1` binary blob, base64-encoded, wrapped in
  /// `-----BEGIN OPENSSH PRIVATE KEY-----` / `-----END ...` markers.
  ///
  /// This is the same format that `ssh-keygen -t ed25519` produces, and
  /// what `SSHKeyPair.fromPem()` (dartssh2) expects to parse.
  static String _encodeOpenSshEd25519Pem({
    required Uint8List privateKeyBytes,
    required Uint8List publicKeyBytes,
  }) {
    // The OpenSSH private key format:
    //   "openssh-key-v1\0"
    //   ciphername (none)
    //   kdfname (none)
    //   kdf options (empty string)
    //   number of keys (1)
    //   public key blob (ssh-ed25519 + 32 bytes)
    //   private key section:
    //     checkint (random 4 bytes — we use a fixed value)
    //     checkint (same value)
    //     ssh-ed25519
    //     public key (32 bytes)
    //     private key (64 bytes — concat of private + public, OpenSSH convention)
    //     comment
    //     padding (1, 2, 3, ...)

    final List<int> bytes = [];

    void writeString(List<int> data) {
      final len = data.length;
      bytes
        ..add((len >> 24) & 0xff)
        ..add((len >> 16) & 0xff)
        ..add((len >> 8) & 0xff)
        ..add(len & 0xff);
      bytes.addAll(data);
    }

    // Magic + version
    bytes.addAll(utf8.encode('openssh-key-v1\0'));

    // ciphername = "none"
    writeString(utf8.encode('none'));
    // kdfname = "none"
    writeString(utf8.encode('none'));
    // kdf options = empty
    writeString([]);

    // number of keys = 1
    bytes..add(0)..add(0)..add(0)..add(1);

    // Public key blob
    final List<int> pubBlob = [];
    void writeStringToBlob(List<int> data) {
      final len = data.length;
      pubBlob
        ..add((len >> 24) & 0xff)
        ..add((len >> 16) & 0xff)
        ..add((len >> 8) & 0xff)
        ..add(len & 0xff);
      pubBlob.addAll(data);
    }
    writeStringToBlob(utf8.encode(_algorithm));
    writeStringToBlob(publicKeyBytes);
    writeString(pubBlob);

    // Private key section
    final List<int> privSection = [];

    void writeStringToPriv(List<int> data) {
      final len = data.length;
      privSection
        ..add((len >> 24) & 0xff)
        ..add((len >> 16) & 0xff)
        ..add((len >> 8) & 0xff)
        ..add(len & 0xff);
      privSection.addAll(data);
    }

    // Two checkints (we use 0x12345678 — not cryptographic, just a
    // consistency check for the parser).
    privSection..add(0x12)..add(0x34)..add(0x56)..add(0x78);
    privSection..add(0x12)..add(0x34)..add(0x56)..add(0x78);

    writeStringToPriv(utf8.encode(_algorithm));
    writeStringToPriv(publicKeyBytes);

    // OpenSSH ed25519 private key is 64 bytes = private (32) + public (32).
    final Uint8List privateAndPublic = Uint8List(64);
    privateAndPublic.setRange(0, 32, privateKeyBytes);
    privateAndPublic.setRange(32, 64, publicKeyBytes);
    writeStringToPriv(privateAndPublic);

    writeStringToPriv(utf8.encode(_comment));

    // Padding (1, 2, 3, ...) to align to cipher block size (8 for "none").
    var pad = 1;
    while (privSection.length % 8 != 0) {
      privSection.add(pad++);
    }

    writeString(privSection);

    // Base64-encode and wrap at 70 chars.
    final base64 = base64Encode(Uint8List.fromList(bytes));
    final lines = <String>[];
    for (var i = 0; i < base64.length; i += 70) {
      lines.add(base64.substring(
          i, i + 70 > base64.length ? base64.length : i + 70));
    }

    return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        '${lines.join('\n')}\n'
        '-----END OPENSSH PRIVATE KEY-----\n';
  }
}
