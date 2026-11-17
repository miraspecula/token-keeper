import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:token_keeper/container.dart';
import 'package:token_keeper/crypto.dart';
import 'package:token_keeper/models.dart';
import 'package:token_keeper/vault_core.dart';

const fast = KdfParams.argon2id(memoryKiB: 64, iterations: 1, parallelism: 1);

VaultData sampleData() => VaultData(
  cards: [
    ServiceCard.create(
      name: 'GitHub',
      token: 'ghp_abc123',
      url: 'github.com',
      colorIndex: 0,
    ),
    ServiceCard.create(
      name: 'NPM',
      token: 'npm_xyz789',
      url: 'npmjs.com',
      colorIndex: 0,
    ),
  ],
  updatedAt: DateTime.now(),
);

void expectSameCards(VaultData a, VaultData b) {
  expect(a.cards.length, b.cards.length);
  for (var i = 0; i < a.cards.length; i++) {
    expect(b.cards[i].id, a.cards[i].id);
    expect(b.cards[i].name, a.cards[i].name);
    expect(b.cards[i].token, a.cards[i].token);
    expect(b.cards[i].url, a.cards[i].url);
  }
}

/// Собирает v1-файл вручную, точно как старый MVP: PBKDF2, без AAD.
({String json, Uint8List dek}) buildLegacyV1(VaultData data, String password) {
  final empty = Uint8List(0);
  final salt = CryptoBox.randomBytes(16);
  final pwk = CryptoBox.deriveKey(password, salt, const KdfParams.pbkdf2(1000));
  final dek = CryptoBox.randomBytes(32);
  final dekNonce = CryptoBox.randomBytes(12);
  final dataNonce = CryptoBox.randomBytes(12);
  final plain = Uint8List.fromList(utf8.encode(data.encode()));
  final json = jsonEncode({
    'v': 1,
    'kdf': {'iters': 1000, 'salt': bytesToB64(salt)},
    'dek': {
      'n': bytesToB64(dekNonce),
      'ct': bytesToB64(CryptoBox.encrypt(pwk, dekNonce, dek, empty)),
    },
    'data': {
      'n': bytesToB64(dataNonce),
      'ct': bytesToB64(CryptoBox.encrypt(dek, dataNonce, plain, empty)),
    },
  });
  wipeBytes(pwk);
  wipeBytes(plain);
  return (json: json, dek: dek);
}

Map<String, dynamic> decodeFile(String s) =>
    Map<String, dynamic>.from(jsonDecode(s) as Map);

void main() {
  test('create + unlock roundtrip through serialize/parse', () {
    final data = sampleData();
    final opened = VaultCore.create('master-pw', data, kdf: fast);
    expect(opened.migrated, isFalse);
    expect(opened.container.version, 2);
    expect(opened.container.kind, 'vault');

    final parsed = VaultContainer.parse(opened.container.serialize());
    final reopened = VaultCore.unlock(parsed, 'master-pw', kdf: fast);
    expect(reopened.migrated, isFalse);
    expectSameCards(reopened.data, data);
  });

  test('wrong password -> WrongPasswordException', () {
    final opened = VaultCore.create('right', sampleData(), kdf: fast);
    expect(
      () => VaultCore.unlock(opened.container, 'wrong', kdf: fast),
      throwsA(isA<WrongPasswordException>()),
    );
  });

  group('tampering and malformed files', () {
    late String goodJson;

    setUp(() {
      goodJson = VaultCore.create(
        'pw',
        sampleData(),
        kdf: fast,
      ).container.serialize();
    });

    test('flipped byte in data.ct -> CorruptVaultException', () {
      final m = decodeFile(goodJson);
      final data = Map<String, dynamic>.from(m['data'] as Map);
      final ct = b64ToBytes(data['ct'] as String);
      ct[0] ^= 0x01;
      data['ct'] = bytesToB64(ct);
      m['data'] = data;
      final c = VaultContainer.parse(jsonEncode(m));
      expect(
        () => VaultCore.unlock(c, 'pw', kdf: fast),
        throwsA(isA<CorruptVaultException>()),
      );
    });

    test('flipped byte in dek.ct -> WrongPasswordException', () {
      final m = decodeFile(goodJson);
      final dek = Map<String, dynamic>.from(m['dek'] as Map);
      final ct = b64ToBytes(dek['ct'] as String);
      ct[0] ^= 0x01;
      dek['ct'] = bytesToB64(ct);
      m['dek'] = dek;
      final c = VaultContainer.parse(jsonEncode(m));
      expect(
        () => VaultCore.unlock(c, 'pw', kdf: fast),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('changing kdf t (header tamper) -> WrongPasswordException', () {
      final m = decodeFile(goodJson);
      final kdf = Map<String, dynamic>.from(m['kdf'] as Map);
      kdf['t'] = 2; // было 1; AAD/KDF больше не совпадают
      m['kdf'] = kdf;
      final c = VaultContainer.parse(jsonEncode(m));
      expect(
        () => VaultCore.unlock(c, 'pw', kdf: fast),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('truncated / garbage JSON -> CorruptVaultException', () {
      expect(
        () => VaultContainer.parse('{'),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => VaultContainer.parse('not json at all'),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => VaultContainer.parse(goodJson.substring(0, 40)),
        throwsA(isA<CorruptVaultException>()),
      );
      expect(
        () => VaultContainer.parse('[1,2,3]'),
        throwsA(isA<CorruptVaultException>()),
      );
    });

    test('v=99 -> UnsupportedVaultException', () {
      final m = decodeFile(goodJson);
      m['v'] = 99;
      expect(
        () => VaultContainer.parse(jsonEncode(m)),
        throwsA(isA<UnsupportedVaultException>()),
      );
    });

    test('kdf m=999999999 -> CorruptVaultException', () {
      final m = decodeFile(goodJson);
      final kdf = Map<String, dynamic>.from(m['kdf'] as Map);
      kdf['m'] = 999999999;
      m['kdf'] = kdf;
      expect(
        () => VaultContainer.parse(jsonEncode(m)),
        throwsA(isA<CorruptVaultException>()),
      );
    });
  });

  test('seal: fresh nonce each time, data survives', () {
    final opened = VaultCore.create('pw', sampleData(), kdf: fast);
    final s1 = VaultCore.seal(opened.container, opened.dek, opened.data);
    final s2 = VaultCore.seal(opened.container, opened.dek, opened.data);
    expect(s1.dataNonce, isNot(s2.dataNonce));
    expect(s1.dataCt, isNot(s2.dataCt));
    final back = VaultCore.unlock(
      VaultContainer.parse(s2.serialize()),
      'pw',
      kdf: fast,
    );
    expectSameCards(back.data, opened.data);
  });

  test('changePassword rotates DEK and salt, preserves data', () {
    final opened = VaultCore.create('old-pw', sampleData(), kdf: fast);
    final changed = VaultCore.changePassword(
      opened.container,
      'old-pw',
      'new-pw',
      kdf: fast,
    );

    expect(changed.dek, isNot(opened.dek));
    expect(changed.container.salt, isNot(opened.container.salt));
    expectSameCards(changed.data, opened.data);

    final c = VaultContainer.parse(changed.container.serialize());
    expect(
      () => VaultCore.unlock(c, 'old-pw', kdf: fast),
      throwsA(isA<WrongPasswordException>()),
    );
    final reopened = VaultCore.unlock(c, 'new-pw', kdf: fast);
    expectSameCards(reopened.data, opened.data);

    expect(
      () =>
          VaultCore.changePassword(opened.container, 'bad-old', 'x', kdf: fast),
      throwsA(isA<WrongPasswordException>()),
    );
  });

  group('export / import', () {
    test('roundtrip preserves cards; independent DEK; kind=export', () {
      final opened = VaultCore.create('vault-pw', sampleData(), kdf: fast);
      final ex1 = VaultCore.exportVault(opened.data, 'export-pw', kdf: fast);
      final ex2 = VaultCore.exportVault(opened.data, 'export-pw', kdf: fast);

      final c1 = VaultContainer.parse(ex1);
      final c2 = VaultContainer.parse(ex2);
      expect(c1.kind, 'export');
      expect(c1.version, 2);

      final imported = VaultCore.importExport(ex1, 'export-pw');
      expectSameCards(imported, opened.data);

      final exDek1 = c1.unwrapDek('export-pw');
      final exDek2 = c2.unwrapDek('export-pw');
      expect(exDek1, isNot(opened.dek)); // никогда не DEK хранилища
      expect(exDek1, isNot(exDek2)); // два экспорта — разные DEK
    });

    test('wrong export password fails', () {
      final opened = VaultCore.create('pw', sampleData(), kdf: fast);
      final ex = VaultCore.exportVault(opened.data, 'export-pw', kdf: fast);
      expect(
        () => VaultCore.importExport(ex, 'nope'),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('tampered export file rejected', () {
      final opened = VaultCore.create('pw', sampleData(), kdf: fast);
      final ex = VaultCore.exportVault(opened.data, 'export-pw', kdf: fast);
      final m = decodeFile(ex);
      final data = Map<String, dynamic>.from(m['data'] as Map);
      final ct = b64ToBytes(data['ct'] as String);
      ct[0] ^= 0x01;
      data['ct'] = bytesToB64(ct);
      m['data'] = data;
      expect(
        () => VaultCore.importExport(jsonEncode(m), 'export-pw'),
        throwsA(isA<CorruptVaultException>()),
      );
    });

    test('vault-kind file is not accepted as export', () {
      final opened = VaultCore.create('pw', sampleData(), kdf: fast);
      expect(
        () => VaultCore.importExport(opened.container.serialize(), 'pw'),
        throwsA(isA<UnsupportedVaultException>()),
      );
    });
  });

  group('legacy v1 migration', () {
    test('unlock migrates to v2 with new DEK, same cards', () {
      final data = sampleData();
      final legacy = buildLegacyV1(data, 'legacy-pw');
      final c = VaultContainer.parse(legacy.json);
      expect(c.version, 1);

      final opened = VaultCore.unlock(c, 'legacy-pw', kdf: fast);
      expect(opened.migrated, isTrue);
      expect(opened.container.version, 2);
      expect(opened.container.kind, 'vault');
      expect(opened.dek, isNot(legacy.dek)); // старый DEK считаем утёкшим
      expectSameCards(opened.data, data);

      // Мигрированный файл открывается как обычный v2.
      final reparsed = VaultContainer.parse(opened.container.serialize());
      final again = VaultCore.unlock(reparsed, 'legacy-pw', kdf: fast);
      expect(again.migrated, isFalse);
      expectSameCards(again.data, data);
    });

    test('v1 file can be imported via importExport', () {
      final data = sampleData();
      final legacy = buildLegacyV1(data, 'legacy-pw');
      final imported = VaultCore.importExport(legacy.json, 'legacy-pw');
      expectSameCards(imported, data);
    });

    test('v1 wrong password fails', () {
      final legacy = buildLegacyV1(sampleData(), 'legacy-pw');
      final c = VaultContainer.parse(legacy.json);
      expect(
        () => VaultCore.unlock(c, 'bad', kdf: fast),
        throwsA(isA<WrongPasswordException>()),
      );
    });
  });

  test('wipeBytes zeroes', () {
    final b = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    wipeBytes(b);
    expect(b.every((x) => x == 0), isTrue);
  });

  test('heavy ops work through Isolate.run (results are sendable)', () async {
    final data = VaultData(
      cards: [
        ServiceCard.create(
          name: 'iso',
          token: 'tok-iso',
          url: null,
          colorIndex: 0,
        ),
      ],
      updatedAt: DateTime.now(),
    );
    final opened = await Isolate.run(
      () => VaultCore.create('isolate-pass', data, kdf: fast),
    );
    final c = VaultContainer.parse(opened.container.serialize());
    final again = await Isolate.run(
      () => VaultCore.unlock(c, 'isolate-pass', kdf: fast),
    );
    expect(again.data.cards.single.token, 'tok-iso');
    expect(again.dek, opened.dek);
  });

  test(
    'default KDF is Argon2id 64 MiB / t=3 / p=1 and is written to the file',
    () {
      expect(KdfParams.standard.alg, 'argon2id');
      expect(KdfParams.standard.memoryKiB, 65536);
      expect(KdfParams.standard.iterations, 3);
      final opened = VaultCore.create('p', VaultData.empty(), kdf: fast);
      final m =
          jsonDecode(opened.container.serialize()) as Map<String, dynamic>;
      expect(m['v'], 2);
      expect(m['format'], 'token-keeper');
      expect((m['kdf'] as Map)['alg'], 'argon2id');
    },
  );
}
