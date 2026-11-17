import 'dart:convert';
import 'dart:typed_data';

import 'container.dart';
import 'crypto.dart';
import 'models.dart';

/// Открытое хранилище: контейнер + DEK + данные.
/// [migrated] = true, если legacy v1 был автоматически переведён в v2.
class OpenedVault {
  final VaultContainer container;
  final Uint8List dek;
  final VaultData data;
  final bool migrated;

  OpenedVault({
    required this.container,
    required this.dek,
    required this.data,
    this.migrated = false,
  });
}

/// Синхронное ядро. Тяжёлые операции приложение запускает в Isolate.run.
/// Весь промежуточный ключевой материал затирается в finally.
class VaultCore {
  /// Новое хранилище: свежая соль, случайный DEK, kind=vault, v2.
  static OpenedVault create(String password, VaultData data,
      {KdfParams kdf = KdfParams.standard}) {
    final built = _build(password, data, 'vault', kdf);
    return OpenedVault(
        container: built.$1, dek: built.$2, data: data);
  }

  /// Открывает контейнер. v1 читается по legacy-правилам и МИГРИРУЕТСЯ
  /// в новый v2 с новой солью и НОВЫМ DEK (старый DEK считаем утёкшим).
  static OpenedVault unlock(VaultContainer c, String password,
      {KdfParams kdf = KdfParams.standard}) {
    if (c.kind != 'vault') {
      throw UnsupportedVaultException('kind ${c.kind} is not a vault');
    }
    final dek = c.unwrapDek(password);
    try {
      final VaultData data;
      try {
        data = c.openData(dek);
      } catch (_) {
        wipeBytes(dek);
        rethrow;
      }
      if (c.version == 1) {
        final built = _build(password, data, 'vault', kdf);
        return OpenedVault(
          container: built.$1,
          dek: built.$2,
          data: data,
          migrated: true,
        );
      }
      return OpenedVault(container: c, dek: dek, data: data);
    } finally {
      // dek либо тот же объект в OpenedVault, либо уже не нужен (v1).
      if (c.version == 1) wipeBytes(dek);
    }
  }

  /// Переупаковывает данные тем же DEK/солью, новый nonce. Только v2.
  static VaultContainer seal(
      VaultContainer c, Uint8List dek, VaultData data) {
    if (c.version != 2) {
      throw StateError('seal requires a v2 container');
    }
    final nonce = CryptoBox.randomBytes(CryptoBox.nonceLength);
    final plain = Uint8List.fromList(utf8.encode(data.encode()));
    try {
      final ct = CryptoBox.encrypt(dek, nonce, plain, _dataAad(c.kind));
      return VaultContainer(
        version: 2,
        kind: c.kind,
        kdf: c.kdf,
        salt: c.salt,
        dekNonce: c.dekNonce,
        dekCt: c.dekCt,
        dataNonce: nonce,
        dataCt: ct,
      );
    } finally {
      wipeBytes(plain);
    }
  }

  /// Смена пароля с РОТАЦИЕЙ DEK: новый DEK + новая соль, данные перешифрованы.
  static OpenedVault changePassword(
      VaultContainer c, String oldPassword, String newPassword,
      {KdfParams kdf = KdfParams.standard}) {
    final oldDek = c.unwrapDek(oldPassword); // WrongPasswordException при ошибке
    try {
      final data = c.openData(oldDek);
      final built = _build(newPassword, data, 'vault', kdf);
      return OpenedVault(container: built.$1, dek: built.$2, data: data);
    } finally {
      wipeBytes(oldDek);
    }
  }

  /// Экспорт: kind=export, независимый случайный DEK (никогда не DEK хранилища).
  static String exportVault(VaultData data, String exportPassword,
      {KdfParams kdf = KdfParams.standard}) {
    final built = _build(exportPassword, data, 'export', kdf);
    try {
      return built.$1.serialize();
    } finally {
      wipeBytes(built.$2);
    }
  }

  /// Импорт: принимает v2 kind=export или legacy v1 (экспорты старого MVP).
  static VaultData importExport(String json, String exportPassword) {
    final c = VaultContainer.parse(json);
    if (!(c.version == 2 && c.kind == 'export') && c.version != 1) {
      throw UnsupportedVaultException('not an export file');
    }
    final dek = c.unwrapDek(exportPassword);
    try {
      return c.openData(dek);
    } finally {
      wipeBytes(dek);
    }
  }

  // --- внутреннее ---

  static Uint8List _dataAad(String kind) =>
      Uint8List.fromList(utf8.encode('token-keeper|v2|$kind|data'));

  static Uint8List _headerAad(String kind, KdfParams kdf, Uint8List salt) =>
      Uint8List.fromList(utf8.encode('token-keeper|v2|$kind|dek|'
          '${kdf.alg}|m=${kdf.memoryKiB}|t=${kdf.iterations}'
          '|p=${kdf.parallelism}|salt=${bytesToB64(salt)}'));

  /// Строит свежий v2-контейнер: новая соль, новый DEK, новые nonce.
  static (VaultContainer, Uint8List) _build(
      String password, VaultData data, String kind, KdfParams kdf) {
    final salt = CryptoBox.randomBytes(CryptoBox.saltLength);
    final dek = CryptoBox.randomBytes(CryptoBox.keyLength);
    Uint8List? pwk;
    Uint8List? plain;
    try {
      pwk = CryptoBox.deriveKey(password, salt, kdf);
      final headerAad = _headerAad(kind, kdf, salt);
      final dekNonce = CryptoBox.randomBytes(CryptoBox.nonceLength);
      final dekCt = CryptoBox.encrypt(pwk, dekNonce, dek, headerAad);
      final dataNonce = CryptoBox.randomBytes(CryptoBox.nonceLength);
      plain = Uint8List.fromList(utf8.encode(data.encode()));
      final dataCt =
          CryptoBox.encrypt(dek, dataNonce, plain, _dataAad(kind));
      final container = VaultContainer(
        version: 2,
        kind: kind,
        kdf: kdf,
        salt: salt,
        dekNonce: dekNonce,
        dekCt: dekCt,
        dataNonce: dataNonce,
        dataCt: dataCt,
      );
      return (container, dek);
    } catch (_) {
      wipeBytes(dek);
      rethrow;
    } finally {
      wipeBytes(pwk);
      wipeBytes(plain);
    }
  }
}
