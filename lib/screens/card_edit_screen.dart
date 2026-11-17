import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../services.dart';
import '../token_check.dart';
import '../widgets.dart';
import 'models_screen.dart';

class CardEditScreen extends StatefulWidget {
  final ServiceCard? existing;

  const CardEditScreen({super.key, this.existing});

  @override
  State<CardEditScreen> createState() => _CardEditScreenState();
}

class _CardEditScreenState extends State<CardEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _token;
  late final TextEditingController _url;
  DateTime? _expiry;
  bool _showToken = false;
  bool _busy = false;
  bool _loadingFavicon = false;
  bool _checking = false;
  CheckResult? _check;
  File? _faviconPreview;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _token = TextEditingController(
      text: TokenText.sanitizeToken(e?.token ?? ''),
    );
    _url = TextEditingController(text: e?.url ?? '');
    _expiry = e?.expiry;
  }

  @override
  void dispose() {
    _name.dispose();
    _token.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry ?? now.add(const Duration(days: 30)),
      firstDate: now,
      lastDate: DateTime(now.year + 30),
      helpText: 'Дата истечения токена',
    );
    if (!mounted || picked == null) return;
    setState(() => _expiry = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _loadFavicon() async {
    if (!AppPrefs.faviconsEnabled.value) return;
    final card = ServiceCard.create(
      name: _name.text.trim().isEmpty ? 'X' : _name.text.trim(),
      token: 'x',
      url: _url.text,
      colorIndex: 0,
    );
    final domain = card.domain;
    if (domain == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Укажите корректный URL')));
      return;
    }
    setState(() => _loadingFavicon = true);
    try {
      final f = await FaviconService.ensureCached(
        domain,
        card.url,
        force: true,
      );
      if (!mounted) return;
      setState(() => _faviconPreview = f);
      if (f == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Иконку найти не удалось — останется буква'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingFavicon = false);
    }
  }

  /// «Проверить»: лёгкий запрос к API сервиса с текущими значениями формы.
  Future<void> _checkToken() async {
    final token = TokenText.sanitizeToken(_token.text);
    if (token.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Введите токен')));
      return;
    }
    setState(() {
      _checking = true;
      _check = null;
    });
    try {
      final r = await TokenService.check(
        url: TokenText.sanitizeUrl(_url.text),
        name: _name.text,
        token: token,
      );
      if (!mounted || r == null) return; // хранилище заблокировано
      setState(() => _check = r);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Проверка при сохранении (только если токен или URL изменились).
  /// Возвращает false, если пользователь решил не сохранять.
  Future<bool> _checkBeforeSave(String token, String? url) async {
    final e = widget.existing;
    final changed =
        e == null || e.token != token || (e.url ?? '') != (url ?? '');
    if (!changed) return true;
    if (Providers.detect(url: url, name: _name.text) == null) return true;
    setState(() {
      _checking = true;
      _check = null;
    });
    CheckResult? r;
    try {
      r = await TokenService.check(url: url, name: _name.text, token: token);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted || r == null) return false;
    setState(() => _check = r);
    if (!r.isInvalid) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Токен отклонён сервисом'),
        content: Text(
          '${r!.provider?.name ?? 'Сервис'} ответил '
          '${r.httpCode != null ? 'HTTP ${r.httpCode}' : 'ошибкой'}: '
          'токен недействителен или отозван.'
          '${r.detail != null ? '\n\n${r.detail}' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Сохранить всё равно'),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _openModels() async {
    final card = widget.existing;
    if (card == null) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ModelsScreen(card: card)));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final token = TokenText.sanitizeToken(_token.text);
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Введите название')));
      return;
    }
    if (token.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Введите токен')));
      return;
    }
    final urlClean = TokenText.sanitizeUrl(_url.text);
    final url0 = urlClean.isEmpty ? null : urlClean;
    if (!await _checkBeforeSave(token, url0)) return;
    if (!mounted) return;
    final checkNote = _check;
    setState(() => _busy = true);
    try {
      final vault = SessionVault.instance;
      final url = url0;
      if (widget.existing == null) {
        final colorIndex = ColorPalette.pickIndex(vault.data!.cards);
        vault.data!.cards.add(
          ServiceCard.create(
            name: name,
            token: token,
            url: url,
            expiry: _expiry,
            colorIndex: colorIndex,
          ),
        );
        try {
          await vault.persist();
        } catch (_) {
          // Откат: убираем добавленную, но не сохранённую карточку.
          vault.data?.cards.removeWhere(
            (c) =>
                c.name == name &&
                c.token == token &&
                c.url == url &&
                c.expiry == _expiry,
          );
          rethrow;
        }
      } else {
        final c = widget.existing!;
        // Запоминаем прежние значения для отката при ошибке записи.
        final prevName = c.name;
        final prevToken = c.token;
        final prevUrl = c.url;
        final prevExpiry = c.expiry;
        final prevUpdatedAt = c.updatedAt;
        final prevModels = c.models;
        // Сменился адрес сервиса — кэш моделей относится к старому.
        if ((prevUrl ?? '') != (url ?? '')) c.models = null;
        c.name = name;
        c.token = token;
        c.url = url;
        c.expiry = _expiry;
        c.updatedAt = DateTime.now();
        try {
          await vault.persist();
        } catch (_) {
          c.name = prevName;
          c.token = prevToken;
          c.url = prevUrl;
          c.expiry = prevExpiry;
          c.updatedAt = prevUpdatedAt;
          c.models = prevModels;
          rethrow;
        }
      }
      // Фоново тянем favicon (не мешаем навигации), только если разрешено.
      if (AppPrefs.faviconsEnabled.value) {
        final d = ServiceCard.create(
          name: name,
          token: token,
          url: url,
          colorIndex: 0,
        );
        FaviconService.prefetch(d.domain, url);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      if (checkNote != null && !checkNote.isValid && !checkNote.isInvalid) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Сохранено. Проверка токена: ${checkNote.title}'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка сохранения: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить карточку?'),
        content: const Text('Токен будет удалён безвозвратно.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      final vault = SessionVault.instance;
      vault.data?.cards.removeWhere((c) => c.id == widget.existing!.id);
      await vault.persist();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка удаления: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _providerHint() {
    final p = Providers.detect(url: _url.text, name: _name.text);
    if (p == null) {
      return 'Сервис не распознан: для проверки укажите URL API';
    }
    return p.known
        ? 'Сервис: ${p.name} (${p.base.host})'
        : 'Неизвестный сервис: проверка как OpenAI-совместимого API (${p.base}/models)';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Новая карточка' : 'Редактирование'),
        actions: [
          if (!isNew)
            IconButton(
              tooltip: 'Удалить',
              icon: const Icon(Icons.delete_outline),
              onPressed: _busy ? null : _delete,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: AppPrefs.faviconsEnabled,
              builder: (context, faviconsOn, _) => Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (_faviconPreview != null && faviconsOn)
                    FaviconImage(
                      file: _faviconPreview!,
                      size: 48,
                      fallback: const SizedBox(width: 48, height: 48),
                    )
                  else if (isNew)
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: ColorPalette.colorFor(
                          ColorPalette.pickIndex(
                            SessionVault.instance.data?.cards ?? const [],
                          ),
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _name.text.trim().isEmpty
                            ? '?'
                            : _name.text.trim()[0].toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    FaviconView(card: widget.existing!, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      faviconsOn ? 'Иконка берётся с сайта по URL.' : 'Иконки сайтов выключены в настройках (приватность).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (faviconsOn)
                    TextButton(
                      onPressed: _loadingFavicon ? null : _loadFavicon,
                      child: Text(_loadingFavicon ? 'Загрузка…' : 'Загрузить'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Название сервиса',
                border: const OutlineInputBorder(),
                suffixIcon: CopyFieldButton(controller: _name),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              onChanged: (_) => setState(() => _check = null),
              obscureText: !_showToken,
              maxLines: 1,
              // Ключ — не текст: без автозамены, подсказок, «умной»
              // пунктуации; пробелы и невидимые символы при вставке удаляются.
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              inputFormatters: [_StripInvisibleFormatter()],
              decoration: InputDecoration(
                labelText: 'Токен',
                helperText: _token.text.isEmpty
                    ? null
                    : 'Длина: ${_token.text.length} симв.',
                border: const OutlineInputBorder(),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FieldIconButton(
                        icon: _showToken
                            ? Icons.visibility_off
                            : Icons.visibility,
                        tooltip: _showToken ? 'Скрыть' : 'Показать',
                        onPressed: () =>
                            setState(() => _showToken = !_showToken),
                      ),
                      CopyFieldButton(controller: _token, secret: true),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              onChanged: (_) => setState(() => _check = null),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [_StripInvisibleFormatter()],
              decoration: InputDecoration(
                labelText: 'URL (необязательно)',
                hintText: 'https://api.example.com/v1',
                helperText: _providerHint(),
                helperMaxLines: 4, // длинный URL своего сервиса не обрезается
                border: const OutlineInputBorder(),
                suffixIcon: CopyFieldButton(controller: _url),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _checking ? null : _checkToken,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_outlined),
                    label: const Text('Проверить'),
                  ),
                ),
                if (widget.existing != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy || _checking ? null : _openModels,
                      icon: const Icon(Icons.list_alt),
                      label: const Text('Модели'),
                    ),
                  ),
                ],
              ],
            ),
            if (_check != null) ...[
              const SizedBox(height: 8),
              CheckResultView(result: _check!),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text(
                      _expiry == null
                          ? 'Срок истечения (не задан)'
                          : 'Истекает ${_two(_expiry!.day)}.${_two(_expiry!.month)}.${_expiry!.year}',
                    ),
                  ),
                ),
                if (_expiry != null)
                  IconButton(
                    tooltip: 'Убрать дату',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _expiry = null),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy || _checking ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _checking
                      ? 'Проверяем токен…'
                      : (_busy ? 'Сохраняем…' : 'Сохранить'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Данные шифруются AES-256-GCM перед записью на диск.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// Удаляет из вставленного/введённого текста пробелы, переносы и невидимые
/// символы (NBSP, U+00AD, zero-width, BOM). В токене и URL их быть не может.
class _StripInvisibleFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final clean = TokenText.sanitizeToken(newValue.text);
    if (clean == newValue.text) return newValue;
    final before = TokenText.sanitizeToken(
      newValue.text.substring(
        0,
        newValue.selection.end.clamp(0, newValue.text.length),
      ),
    );
    return TextEditingValue(
      text: clean,
      selection: TextSelection.collapsed(offset: before.length),
    );
  }
}
