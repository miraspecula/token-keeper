import 'package:material_ui/material_ui.dart';

import '../models.dart';
import '../services.dart';
import '../token_check.dart';
import '../widgets.dart';
import 'card_edit_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _query = '';

  List<ServiceCard> _visible() {
    final data = SessionVault.instance.data;
    if (data == null) return const [];
    var cards = List<ServiceCard>.from(data.cards);
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      cards = cards
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              (c.domain ?? '').contains(q) ||
              c.token.toLowerCase().contains(q))
          .toList();
    }

    int cmp(ServiceCard a, ServiceCard b) {
      switch (AppPrefs.sortMode.value) {
        case SortMode.added:
          return b.createdAt.compareTo(a.createdAt);
        case SortMode.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SortMode.domain:
          return (a.domain ?? '')
              .toLowerCase()
              .compareTo((b.domain ?? '').toLowerCase());
        case SortMode.expiry:
          return (a.expiry ?? DateTime(9999))
              .compareTo(b.expiry ?? DateTime(9999));
      }
    }

    // Просроченные всегда внизу списка.
    final alive = cards.where((c) => !c.isExpired).toList()..sort(cmp);
    final expired = cards.where((c) => c.isExpired).toList()..sort(cmp);
    return [...alive, ...expired];
  }

  Future<void> _copy(ServiceCard c) async {
    ClipboardService.copyToken(TokenText.sanitizeToken(c.token));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Скопировано. Буфер очистится через 45 сек.')),
    );
  }

  Future<void> _share(ServiceCard c) async {
    await ShareService.shareToken(c);
  }

  Future<void> _openEdit([ServiceCard? card]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardEditScreen(existing: card),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cards = _visible();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token Keeper'),
        actions: [
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Поиск по названию, домену, токену',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<SortMode>(
                  valueListenable: AppPrefs.sortMode,
                  builder: (context, mode, _) => DropdownButton<SortMode>(
                    value: mode,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(
                          value: SortMode.added, child: Text('По добавлению')),
                      DropdownMenuItem(
                          value: SortMode.name, child: Text('По названию')),
                      DropdownMenuItem(
                          value: SortMode.domain, child: Text('По домену')),
                      DropdownMenuItem(
                          value: SortMode.expiry, child: Text('По сроку')),
                    ],
                    onChanged: (m) {
                      if (m != null) AppPrefs.setSortMode(m);
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: cards.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty
                          ? 'Пусто. Добавьте первую карточку.'
                          : 'Ничего не найдено',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    itemCount: cards.length,
                    itemBuilder: (context, i) {
                      final c = cards[i];
                      return ServiceTile(
                        card: c,
                        onTap: () => _openEdit(c),
                        onCopy: () => _copy(c),
                        onShare: () => _share(c),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEdit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}
