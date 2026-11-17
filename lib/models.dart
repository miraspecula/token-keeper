import 'dart:convert';

import 'crypto.dart';

/// Карточка сервиса: название, токен, необязательный URL и дата истечения.
class ServiceCard {
  final String id;
  String name;
  String token;
  String? url;
  /// Дата истечения. Хранится как календарная дата (время — полночь).
  DateTime? expiry;
  int colorIndex;
  final DateTime createdAt;
  DateTime updatedAt;

  /// Кэш списка моделей сервиса (хранится в зашифрованном хранилище).
  /// Необязательное поле: старые файлы без него читаются как null.
  ModelsCache? models;

  ServiceCard({
    required this.id,
    required this.name,
    required this.token,
    this.url,
    this.expiry,
    required this.colorIndex,
    required this.createdAt,
    required this.updatedAt,
    this.models,
  });

  factory ServiceCard.create({
    required String name,
    required String token,
    String? url,
    DateTime? expiry,
    required int colorIndex,
  }) {
    final now = DateTime.now();
    return ServiceCard(
      id: _newId(),
      name: name,
      token: token,
      url: (url == null || url.trim().isEmpty) ? null : url.trim(),
      expiry: expiry,
      colorIndex: colorIndex,
      createdAt: now,
      updatedAt: now,
    );
  }

  static String _newId() {
    final bytes = CryptoBox.randomBytes(12);
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String? get domain {
    final u = url;
    if (u == null) return null;
    final trimmed = u.trim();
    if (trimmed.isEmpty) return null;
    try {
      final withScheme = trimmed.startsWith('http') ? trimmed : 'https://$trimmed';
      final host = Uri.parse(withScheme).host;
      return host.isEmpty ? null : host;
    } catch (_) {
      return null;
    }
  }

  /// Просрочен: дата истечения раньше сегодняшнего дня.
  bool get isExpired {
    final e = expiry;
    if (e == null) return false;
    final now = DateTime.now();
    return e.isBefore(DateTime(now.year, now.month, now.day));
  }

  /// Истекает в течение 7 дней (но ещё не просрочен).
  bool get isExpiringSoon {
    final e = expiry;
    if (e == null || isExpired) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return e.difference(today).inDays <= 7;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'token': token,
        'url': url,
        'expiry': expiry?.toIso8601String(),
        'colorIndex': colorIndex,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (models != null) 'models': models!.toJson(),
      };

  factory ServiceCard.fromJson(Map<String, dynamic> j) => ServiceCard(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        token: j['token'] as String? ?? '',
        url: j['url'] as String?,
        expiry:
            j['expiry'] == null ? null : DateTime.tryParse(j['expiry'] as String),
        colorIndex: j['colorIndex'] as int? ?? 0,
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        updatedAt:
            DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
        models: ModelsCache.fromJson(j['models']),
      );
}

/// Всё содержимое хранилища (расшифрованное состояние).
class VaultData {
  List<ServiceCard> cards;
  DateTime updatedAt;

  VaultData({required this.cards, required this.updatedAt});

  /// Версия схемы расшифрованных данных: 2 — карточки могут содержать
  /// необязательный кэш моделей. Старые данные (без поля) читаются как есть.
  static const int schema = 2;

  String encode() => jsonEncode({
        'schema': schema,
        'updatedAt': updatedAt.toIso8601String(),
        'cards': cards.map((c) => c.toJson()).toList(),
      });

  static VaultData decode(String s) {
    final map = Map<String, dynamic>.from(jsonDecode(s) as Map);
    final cardsRaw = map['cards'];
    return VaultData(
      updatedAt:
          DateTime.tryParse(map['updatedAt'] as String? ?? '') ?? DateTime.now(),
      cards: (cardsRaw as List<dynamic>? ?? [])
          .map((e) => ServiceCard.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }

  static VaultData empty() =>
      VaultData(cards: [], updatedAt: DateTime.now());
}

enum SortMode { added, domain, name, expiry }

enum ThemePref { light, dark, system }

/// Модель сервиса из списка `/models` (или аналога у провайдера).
class ModelInfo {
  final String id;
  final String? name;
  final String? owner;
  final int? contextLength;
  const ModelInfo(this.id, {this.name, this.owner, this.contextLength});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': ?name,
        'owner': ?owner,
        'ctx': ?contextLength,
      };

  static ModelInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    final name = j['name'];
    final owner = j['owner'];
    final ctx = j['ctx'];
    return ModelInfo(id,
        name: name is String ? name : null,
        owner: owner is String ? owner : null,
        contextLength: ctx is int ? ctx : null);
  }
}

/// Кэш списка моделей карточки с датой обновления.
class ModelsCache {
  final List<ModelInfo> items;
  final DateTime fetchedAt;
  final String? providerId;
  const ModelsCache(
      {required this.items, required this.fetchedAt, this.providerId});

  Map<String, dynamic> toJson() => {
        'fetchedAt': fetchedAt.toIso8601String(),
        'provider': ?providerId,
        'items': items.map((m) => m.toJson()).toList(),
      };

  /// Терпимый разбор: мусор/отсутствие поля → null, битые элементы пропускаются.
  static ModelsCache? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['fetchedAt'];
    final items = j['items'];
    if (at is! String || items is! List) return null;
    final when = DateTime.tryParse(at);
    if (when == null) return null;
    final p = j['provider'];
    return ModelsCache(
      items: [
        for (final e in items) ?ModelInfo.fromJson(e)
      ],
      fetchedAt: when,
      providerId: p is String ? p : null,
    );
  }
}
