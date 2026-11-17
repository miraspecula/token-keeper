import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../services.dart';
import '../token_check.dart';
import '../widgets.dart';

/// Список моделей сервиса карточки: кэш из хранилища + обновление по кнопке.
class ModelsScreen extends StatefulWidget {
  final ServiceCard card;
  const ModelsScreen({super.key, required this.card});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  final _search = TextEditingController();
  bool _loading = false;
  CheckResult? _error;

  ModelsCache? get _cache => widget.card.models;

  @override
  void initState() {
    super.initState();
    // Экран открыт явным нажатием «Модели»: если кэша нет — загружаем сразу.
    if (_cache == null) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await TokenService.refreshModels(widget.card);
      if (!mounted || r == null) return; // заблокировано — результат игнорируем
      setState(() => _error = r.check.isValid ? null : r.check);
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = const CheckResult(CheckStatus.error, detail: 'ошибка записи'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');
  String _fmt(DateTime d) =>
      '${_two(d.day)}.${_two(d.month)}.${d.year} ${_two(d.hour)}:${_two(d.minute)}';

  @override
  Widget build(BuildContext context) {
    final provider = Providers.detect(url: widget.card.url, name: widget.card.name);
    final cache = _cache;
    final q = _search.text.trim().toLowerCase();
    final items = (cache?.items ?? const <ModelInfo>[])
        .where((m) =>
            q.isEmpty ||
            m.id.toLowerCase().contains(q) ||
            (m.name?.toLowerCase().contains(q) ?? false))
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Модели · ${provider?.name ?? widget.card.name}'),
        actions: [
          IconButton(
            tooltip: 'Обновить список',
            onPressed: _loading || provider == null ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Поиск модели',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(_search.clear),
                      ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: CheckResultView(result: _error!),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              cache == null
                  ? (provider == null
                      ? 'Сервис не распознан — укажите URL API в карточке.'
                      : 'Список ещё не загружен.')
                  : 'Обновлено ${_fmt(cache.fetchedAt)} · ${cache.items.length} моделей'
                      '${q.isEmpty ? '' : ' · найдено ${items.length}'}. '
                      'Нажмите, чтобы скопировать id.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          ),
          Expanded(
            child: ListView.builder(
              // FAB здесь нет; снизу — только системная панель и небольшой запас.
              padding: EdgeInsets.only(
                  bottom: 8 + MediaQuery.paddingOf(context).bottom),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final m = items[i];
                final sub = [
                  if (m.name != null && m.name != m.id) m.name!,
                  if (m.owner != null) m.owner!,
                  if (m.contextLength != null) 'контекст ${m.contextLength}',
                ].join(' · ');
                return ListTile(
                  dense: true,
                  title: Text(m.id),
                  subtitle: sub.isEmpty ? null : Text(sub),
                  trailing: FieldIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: 'Копировать',
                    onPressed: () => copyWithFeedback(context, m.id),
                  ),
                  onTap: () => copyWithFeedback(context, m.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
