import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show InvalidCipherTextException;

import 'crypto.dart';
import 'models.dart';

/// Зашифрованный контейнер (хранилище или экспорт).
///
/// v2: {"format":"token-keeper","v":2,"kind":"vault"|"export",
///      "kdf":{"alg","m","t","p","salt"},"dek":{"n","ct"},"data":{"n","ct"}}
/// AAD привязывает kind + параметры KDF к обёрнутому DEK и к данным.
/// v1 (legacy MVP): PBKDF2, без AAD, kind=vault; только чтение + миграция.
class VaultContainer {
  final int version;
  final String kind;
  final KdfParams kdf;
  final Uint8List salt;
  final Uint8List dekNonce, dekCt, dataNonce, dataCt;

  VaultContainer({
    required this.version,
    required this.kind,
    required this.kdf,
    required this.salt,
    required this.dekNonce,
    required this.dekCt,
    required this.dataNonce,
    required this.dataCt,
  });

  Uint8List get _headerAad => version == 1
      ? Uint8List(0)
      : Uint8List.fromList(utf8.encode('token-keeper|v2|$kind|dek|'
          '${kdf.alg}|m=${kdf.memoryKiB}|t=${kdf.iterations}'
          '|p=${kdf.parallelism}|salt=${bytesToB64(salt)}'));

  Uint8List get _dataAad => version == 1
      ? Uint8List(0)
      : Uint8List.fromList(utf8.encode('token-keeper|v2|$kind|data'));

  /// Разворачивает DEK по паролю. Ошибка AEAD -> [WrongPasswordException].
  Uint8List unwrapDek(String password) {
    final pwk = CryptoBox.deriveKey(password, salt, kdf);
    try {
      final dek = CryptoBox.decrypt(pwk, dekNonce, dekCt, _headerAad);
      if (dek.length != CryptoBox.keyLength) {
        wipeBytes(dek);
        throw CorruptVaultException('dek length');
      }
      return dek;
    } on InvalidCipherTextException {
      throw WrongPasswordException();
    } on ArgumentError {
      throw WrongPasswordException();
    } finally {
      wipeBytes(pwk);
    }
  }

  /// Расшифровывает данные. Любая ошибка -> [CorruptVaultException].
  VaultData openData(Uint8List dek) {
    Uint8List? plain;
    try {
      plain = CryptoBox.decrypt(dek, dataNonce, dataCt, _dataAad);
      return VaultData.decode(utf8.decode(plain));
    } catch (_) {
      throw CorruptVaultException('data');
    } finally {
      wipeBytes(plain);
    }
  }

  /// Всегда пишет v2. Для legacy-контейнера бросает [StateError].
  Map<String, dynamic> toMap() {
    if (version != 2) {
      throw StateError('legacy v1 container is read-only');
    }
    return {
      'format': 'token-keeper',
      'v': 2,
      'kind': kind,
      'kdf': kdf.toJson(salt),
      'dek': {'n': bytesToB64(dekNonce), 'ct': bytesToB64(dekCt)},
      'data': {'n': bytesToB64(dataNonce), 'ct': bytesToB64(dataCt)},
    };
  }

  String serialize() => jsonEncode(toMap());

  /// Строгий разбор. Мусор -> [CorruptVaultException], v>2 -> [UnsupportedVaultException].
  static VaultContainer parse(String json) {
    final Map<String, dynamic> m;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) throw CorruptVaultException('not an object');
      m = Map<String, dynamic>.from(decoded);
    } on CorruptVaultException {
      rethrow;
    } catch (_) {
      throw CorruptVaultException('json');
    }

    if (m.containsKey('format') && m['format'] != 'token-keeper') {
      throw CorruptVaultException('format');
    }
    final v = m['v'];
    if (v is! int || v < 1) throw CorruptVaultException('version');
    if (v > 2) throw UnsupportedVaultException('vault version $v');

    try {
      final kdfMap = Map<String, dynamic>.from(m['kdf'] as Map);
      final dekMap = Map<String, dynamic>.from(m['dek'] as Map);
      final dataMap = Map<String, dynamic>.from(m['data'] as Map);
      final salt = b64ToBytes(kdfMap['salt'] as String);
      final dekNonce = b64ToBytes(dekMap['n'] as String);
      final dekCt = b64ToBytes(dekMap['ct'] as String);
      final dataNonce = b64ToBytes(dataMap['n'] as String);
      final dataCt = b64ToBytes(dataMap['ct'] as String);

      if (salt.length < CryptoBox.saltLength ||
          dekNonce.length != CryptoBox.nonceLength ||
          dataNonce.length != CryptoBox.nonceLength ||
          dekCt.length < 16 ||
          dataCt.length < 16) {
        throw CorruptVaultException('field lengths');
      }

      if (v == 1) {
        final it = kdfMap['iters'];
        final iters = it is int ? it : 310000;
        if (iters < 1000 || iters > 5000000) {
          throw CorruptVaultException('kdf ranges');
        }
        return VaultContainer(
          version: 1,
          kind: 'vault',
          kdf: KdfParams.pbkdf2(iters),
          salt: salt,
          dekNonce: dekNonce,
          dekCt: dekCt,
          dataNonce: dataNonce,
          dataCt: dataCt,
        );
      }

      final kind = m['kind'];
      if (kind != 'vault' && kind != 'export') {
        throw CorruptVaultException('kind');
      }
      return VaultContainer(
        version: 2,
        kind: kind as String,
        kdf: KdfParams.fromJson(kdfMap),
        salt: salt,
        dekNonce: dekNonce,
        dekCt: dekCt,
        dataNonce: dataNonce,
        dataCt: dataCt,
      );
    } on CorruptVaultException {
      rethrow;
    } on UnsupportedVaultException {
      rethrow;
    } catch (_) {
      throw CorruptVaultException('structure');
    }
  }
}
