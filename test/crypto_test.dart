import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' show InvalidCipherTextException;
import 'package:token_keeper/crypto.dart';

const fast = KdfParams.argon2id(memoryKiB: 64, iterations: 1, parallelism: 1);

String hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('Argon2id known-answer vector', () {
    final key = CryptoBox.deriveKey(
      'correct horse battery',
      Uint8List(16), // 16 нулевых байт
      const KdfParams.argon2id(memoryKiB: 19456, iterations: 2, parallelism: 1),
    );
    expect(key.length, 32);
    expect(
      hex(key),
      '85b5f905c47855c01182e205e9eb538f766e07d694027a3358a5d5f0aeb45dc5',
    );
  });

  test('deriveKey deterministic for same salt, different for other salt', () {
    final salt = CryptoBox.randomBytes(CryptoBox.saltLength);
    final a = CryptoBox.deriveKey('pw', salt, fast);
    final b = CryptoBox.deriveKey('pw', salt, fast);
    final c = CryptoBox.deriveKey(
      'pw',
      CryptoBox.randomBytes(CryptoBox.saltLength),
      fast,
    );
    expect(a, b);
    expect(a, isNot(c));
  });

  group('AES-256-GCM', () {
    final key = CryptoBox.randomBytes(32);
    final nonce = CryptoBox.randomBytes(12);
    final plain = Uint8List.fromList(utf8.encode('секретные данные 🌰'));
    final aad = Uint8List.fromList(utf8.encode('token-keeper|v2|vault|data'));

    test('roundtrip', () {
      final ct = CryptoBox.encrypt(key, nonce, plain, aad);
      expect(ct.length, plain.length + 16); // 128-битный тег
      expect(CryptoBox.decrypt(key, nonce, ct, aad), plain);
    });

    test('wrong AAD throws', () {
      final ct = CryptoBox.encrypt(key, nonce, plain, aad);
      final badAad = Uint8List.fromList(utf8.encode('other-aad'));
      expect(
        () => CryptoBox.decrypt(key, nonce, ct, badAad),
        throwsA(isA<InvalidCipherTextException>()),
      );
    });

    test('tampered ciphertext throws', () {
      final ct = CryptoBox.encrypt(key, nonce, plain, aad);
      ct[0] ^= 0x01;
      expect(
        () => CryptoBox.decrypt(key, nonce, ct, aad),
        throwsA(isA<InvalidCipherTextException>()),
      );
    });

    test('wrong key throws', () {
      final ct = CryptoBox.encrypt(key, nonce, plain, aad);
      final otherKey = CryptoBox.randomBytes(32);
      expect(
        () => CryptoBox.decrypt(otherKey, nonce, ct, aad),
        throwsA(isA<InvalidCipherTextException>()),
      );
    });
  });

  test('200 random nonces are distinct', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final n = CryptoBox.randomBytes(CryptoBox.nonceLength);
      expect(n.length, 12);
      expect(seen.add(bytesToB64(n)), isTrue);
    }
  });

  test('wipeBytes zeroes buffer and is null-safe', () {
    final b = Uint8List.fromList([1, 2, 3, 255]);
    wipeBytes(b);
    expect(b, [0, 0, 0, 0]);
    expect(() => wipeBytes(null), returnsNormally);
  });

  test('base64 helpers roundtrip', () {
    final b = CryptoBox.randomBytes(48);
    expect(b64ToBytes(bytesToB64(b)), b);
  });

  group('KdfParams validation', () {
    test('standard roundtrip', () {
      final salt = CryptoBox.randomBytes(16);
      final p = KdfParams.fromJson(KdfParams.standard.toJson(salt));
      expect(p.alg, 'argon2id');
      expect(p.memoryKiB, 65536);
      expect(p.iterations, 3);
      expect(p.parallelism, 1);
    });

    test('out-of-range values rejected', () {
      Map<String, dynamic> j(int m, int t, int p) => {
        'alg': 'argon2id',
        'm': m,
        't': t,
        'p': p,
      };
      expect(
        () => KdfParams.fromJson(j(999999999, 3, 1)),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => KdfParams.fromJson(j(4, 3, 1)),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => KdfParams.fromJson(j(64, 11, 1)),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => KdfParams.fromJson(j(64, 1, 5)),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => KdfParams.fromJson(j(8, 1, 4)), // m < 8*p
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => KdfParams.fromJson({'alg': 'pbkdf2-sha256', 'iters': 10}),
        throwsA(isA<CorruptVaultException>()),
      );
    });

    test('unknown algorithm rejected', () {
      expect(
        () => KdfParams.fromJson({'alg': 'scrypt'}),
        throwsA(isA<UnsupportedVaultException>()),
      );
    });
  });
}
