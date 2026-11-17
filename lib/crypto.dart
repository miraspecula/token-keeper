import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Параметры KDF. Argon2id (RFC 9106) для v2, PBKDF2 — только legacy v1.
class KdfParams {
  final String alg; // 'argon2id' | 'pbkdf2-sha256'
  final int memoryKiB; // argon2 m
  final int iterations; // argon2 t или pbkdf2 iterations
  final int parallelism; // argon2 p

  const KdfParams.argon2id({
    this.memoryKiB = 65536,
    this.iterations = 3,
    this.parallelism = 1,
  }) : alg = 'argon2id';

  const KdfParams.pbkdf2(this.iterations)
      : alg = 'pbkdf2-sha256',
        memoryKiB = 0,
        parallelism = 1;

  /// RFC 9106, второй рекомендованный набор: 64 MiB, t=3, p=1.
  static const KdfParams standard = KdfParams.argon2id();

  Map<String, dynamic> toJson(Uint8List salt) => {
        'alg': alg,
        'm': memoryKiB,
        't': iterations,
        'p': parallelism,
        'salt': bytesToB64(salt),
      };

  /// Строгая валидация диапазонов: защита от DoS через подделанный файл.
  static KdfParams fromJson(Map<String, dynamic> j) {
    final alg = j['alg'];
    if (alg == 'argon2id') {
      final m = _asInt(j['m']);
      final t = _asInt(j['t']);
      final p = _asInt(j['p']);
      if (m == null || t == null || p == null) {
        throw CorruptVaultException('kdf params');
      }
      if (p < 1 || p > 4 ||
          t < 1 || t > 10 ||
          m < 8 || m > 1048576 ||
          m < 8 * p) {
        throw CorruptVaultException('kdf ranges');
      }
      return KdfParams.argon2id(
          memoryKiB: m, iterations: t, parallelism: p);
    }
    if (alg == 'pbkdf2-sha256') {
      final it = _asInt(j['iters']) ?? _asInt(j['t']);
      if (it == null || it < 1000 || it > 5000000) {
        throw CorruptVaultException('kdf ranges');
      }
      return KdfParams.pbkdf2(it);
    }
    throw UnsupportedVaultException('unknown kdf: $alg');
  }

  static int? _asInt(Object? v) => v is int ? v : null;
}

/// Неверный пароль ИЛИ повреждённый блок ключа (AEAD не сошёлся).
class WrongPasswordException implements Exception {}

/// Файл структурно повреждён / параметры вне допустимых диапазонов.
class CorruptVaultException implements Exception {
  final String message;
  CorruptVaultException(this.message);
  @override
  String toString() => 'CorruptVaultException: $message';
}

/// Версия/алгоритм новее, чем понимает это приложение.
class UnsupportedVaultException implements Exception {
  final String message;
  UnsupportedVaultException(this.message);
  @override
  String toString() => 'UnsupportedVaultException: $message';
}

/// Криптопримитивы: KDF из мастер-пароля + AES-256-GCM с AAD.
class CryptoBox {
  static const int keyLength = 32; // 256 бит
  static const int nonceLength = 12; // GCM nonce
  static const int saltLength = 16;

  static Uint8List randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static String randomId() => randomBytes(12)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// Argon2id v1.3 или PBKDF2-HMAC-SHA256. Буфер пароля затирается.
  static Uint8List deriveKey(String password, Uint8List salt, KdfParams p) {
    final pw = Uint8List.fromList(utf8.encode(password));
    try {
      switch (p.alg) {
        case 'argon2id':
          final gen = Argon2BytesGenerator()
            ..init(Argon2Parameters(
              Argon2Parameters.ARGON2_id,
              salt,
              desiredKeyLength: keyLength,
              iterations: p.iterations,
              memory: p.memoryKiB,
              lanes: p.parallelism,
              version: Argon2Parameters.ARGON2_VERSION_13,
            ));
          return gen.process(pw);
        case 'pbkdf2-sha256':
          final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
            ..init(Pbkdf2Parameters(salt, p.iterations, keyLength));
          return kdf.process(pw);
        default:
          throw UnsupportedVaultException('unknown kdf: ${p.alg}');
      }
    } finally {
      wipeBytes(pw);
    }
  }

  /// AES-256-GCM. Возвращает шифротекст с 128-битным тегом в конце.
  static Uint8List encrypt(
      Uint8List key, Uint8List nonce, Uint8List plain, Uint8List aad) {
    final c = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, aad));
    return c.process(plain);
  }

  /// Бросает [InvalidCipherTextException] при неверном теге/ключе/AAD.
  static Uint8List decrypt(
      Uint8List key, Uint8List nonce, Uint8List ct, Uint8List aad) {
    final c = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, nonce, aad));
    return c.process(ct);
  }
}

/// Затирает буфер нулями (null-safe).
void wipeBytes(Uint8List? b) {
  if (b == null) return;
  for (var i = 0; i < b.length; i++) {
    b[i] = 0;
  }
}

String bytesToB64(List<int> b) => base64Encode(b);

Uint8List b64ToBytes(String s) => Uint8List.fromList(base64Decode(s));
