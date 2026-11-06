import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// On-device, password-encrypted and authenticated portable backup envelope.
///
/// The SQLite snapshot is logical (not a copy of WAL/main database files).
/// No key or password is persisted. Forgotten passwords are unrecoverable.
class BackupCodec {
  BackupCodec._();

  static const format = 'kaibao.encrypted.backup';
  static const version = 1;
  static const iterations = 210000;
  static const maxEncryptedBytes = 64 * 1024 * 1024;

  static void _checkPassword(String password) {
    if (password.runes.length < 12) {
      throw const FormatException('备份密码至少需要 12 个字符');
    }
  }

  static Future<Uint8List> encrypt(String snapshotJson, String password) async {
    _checkPassword(password);
    final bytes = utf8.encode(snapshotJson);
    if (bytes.length > maxEncryptedBytes ~/ 2) {
      throw const FormatException('备份数据过大，当前版本不支持');
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final nonce = AesGcm.with256bits().newNonce();
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    final key = await kdf.deriveKeyFromPassword(password: password, nonce: salt);
    final box = await AesGcm.with256bits().encrypt(bytes,
      secretKey: key, nonce: nonce);
    final envelope = jsonEncode({
      'format': format, 'version': version,
      'cipher': 'AES-256-GCM', 'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    });
    return Uint8List.fromList(utf8.encode(envelope));
  }

  static Future<String> decrypt(List<int> encrypted, String password) async {
    if (encrypted.isEmpty || encrypted.length > maxEncryptedBytes) {
      throw const FormatException('备份文件大小不合法');
    }
    try {
      final obj = jsonDecode(utf8.decode(encrypted));
      if (obj is! Map<String, dynamic> ||
          obj['format'] != format || obj['version'] != version ||
          obj['cipher'] != 'AES-256-GCM' ||
          obj['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          obj['iterations'] != iterations) {
        throw const FormatException('不支持的备份文件或版本');
      }
      final salt = base64Decode(obj['salt'] as String);
      final nonce = base64Decode(obj['nonce'] as String);
      final mac = base64Decode(obj['mac'] as String);
      final ciphertext = base64Decode(obj['ciphertext'] as String);
      if (salt.length != 16 || nonce.length != 12 || mac.length != 16 ||
          ciphertext.length > maxEncryptedBytes ~/ 2) {
        throw const FormatException('备份文件结构已损坏');
      }
      final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
      final key = await kdf.deriveKeyFromPassword(password: password, nonce: salt);
      final box = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
      final clear = await AesGcm.with256bits().decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const FormatException('密码错误或备份文件已被篡改');
    } on FormatException {
      rethrow;
    } on TypeError {
      throw const FormatException('备份文件结构不合法');
    } on ArgumentError {
      throw const FormatException('备份文件编码不合法');
    }
  }
}
