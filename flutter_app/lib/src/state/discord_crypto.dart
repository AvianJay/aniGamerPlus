import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Versioned password encryption. Neither the password nor derived key is saved.
class DiscordCipher {
  static const iterations = 600000;
  static final _aes = AesGcm.with256bits();

  static List<int> randomBytes(int count) {
    final random = Random.secure();
    return List.generate(count, (_) => random.nextInt(256));
  }

  static Future<SecretKey> _key(String password, List<int> salt) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<Map<String, dynamic>> encrypt(
      String token, String password, String account) async {
    if (password.isEmpty || token.isEmpty || token.length > 2000) {
      throw const FormatException('Invalid credentials');
    }
    final salt = randomBytes(16);
    final box = await _aes.encrypt(utf8.encode(token),
        secretKey: await _key(password, salt),
        aad: utf8.encode('agp-discord-v1:$account'));
    return {
      'v': 1,
      'kdf': 'pbkdf2-sha256',
      'iterations': iterations,
      'salt': base64Encode(salt),
      ...encodeBox(box),
    };
  }

  static Future<String> decrypt(
      Map<String, dynamic> value, String password, String account) async {
    if (value['v'] != 1 ||
        value['kdf'] != 'pbkdf2-sha256' ||
        value['iterations'] != iterations) {
      throw const FormatException('Unsupported credentials');
    }
    final salt = bytes(value['salt'], 16);
    return utf8.decode(await _aes.decrypt(decodeBox(value),
        secretKey: await _key(password, salt),
        aad: utf8.encode('agp-discord-v1:$account')));
  }

  static Map<String, dynamic> encodeBox(SecretBox box) => {
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      };

  static List<int> bytes(dynamic value, int length) {
    if (value is! String || value.length > 5500) {
      throw const FormatException('Invalid ciphertext');
    }
    final decoded = base64Decode(value);
    if (decoded.length != length) {
      throw const FormatException('Invalid ciphertext');
    }
    return decoded;
  }

  static SecretBox decodeBox(Map<String, dynamic> value) {
    final raw = value['ciphertext'];
    if (raw is! String || raw.length > 5500) {
      throw const FormatException('Invalid ciphertext');
    }
    final cipher = base64Decode(raw);
    if (cipher.isEmpty || cipher.length > 4096) {
      throw const FormatException('Invalid ciphertext');
    }
    return SecretBox(cipher,
        nonce: bytes(value['nonce'], 12), mac: Mac(bytes(value['mac'], 16)));
  }
}

/// A fresh ephemeral key and challenge for each authenticated TV connection.
/// Replays are rejected by the host before a decrypted credential is accepted.
class DiscordTransfer {
  DiscordTransfer._(this._key, this.publicKey, this.challenge);
  final SimpleKeyPair _key;
  final String publicKey;
  final String challenge;
  static final _x = X25519();
  static final _aes = AesGcm.with256bits();

  static Future<DiscordTransfer> create() async {
    final key = await _x.newKeyPair();
    return DiscordTransfer._(
        key,
        base64Encode((await key.extractPublicKey()).bytes),
        base64Encode(DiscordCipher.randomBytes(32)));
  }

  static Future<SecretKey> _shared(SimpleKeyPair key, String remote,
      String challenge, String binding) async {
    final shared = await _x.sharedSecretKey(
        keyPair: key,
        remotePublicKey: SimplePublicKey(DiscordCipher.bytes(remote, 32),
            type: KeyPairType.x25519));
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: shared,
        nonce: DiscordCipher.bytes(challenge, 32),
        info: utf8.encode('agp-discord-tv-v1:$binding'));
  }

  static Future<Map<String, dynamic>> seal(String token, String name,
      String remoteKey, String challenge, String binding) async {
    final key = await _x.newKeyPair();
    final box = await _aes.encrypt(
        utf8.encode(jsonEncode({'token': token, 'name': name})),
        secretKey: await _shared(key, remoteKey, challenge, binding),
        aad: utf8.encode(challenge));
    return {
      'key': base64Encode((await key.extractPublicKey()).bytes),
      'challenge': challenge,
      ...DiscordCipher.encodeBox(box)
    };
  }

  Future<({String token, String name})> open(
      Map<String, dynamic> value, String binding) async {
    if (value['challenge'] != challenge || value['key'] is! String) {
      throw const FormatException('Invalid transfer');
    }
    final plain = await _aes.decrypt(DiscordCipher.decodeBox(value),
        secretKey: await _shared(_key, value['key'], challenge, binding),
        aad: utf8.encode(challenge));
    final data = jsonDecode(utf8.decode(plain));
    if (data is! Map ||
        data['token'] is! String ||
        data['name'] is! String ||
        (data['token'] as String).isEmpty ||
        (data['token'] as String).length > 2000 ||
        (data['name'] as String).length > 100) {
      throw const FormatException('Invalid transfer');
    }
    return (token: data['token'] as String, name: data['name'] as String);
  }
}
