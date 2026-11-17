/// Public Suffix List (https://publicsuffix.org): вычисление регистрируемого
/// домена (eTLD+1). Список вшит в приложение как ассет и по сети не
/// обновляется. Учитываются обе секции, ICANN и PRIVATE (github.io и т.п.),
/// а также правила-маски (`*.ck`) и исключения (`!www.ck`).
class PublicSuffixList {
  final Set<String> _rules;
  final Set<String> _wildcards; // "ck" для правила "*.ck"
  final Set<String> _exceptions; // "www.ck" для правила "!www.ck"

  PublicSuffixList._(this._rules, this._wildcards, this._exceptions);

  factory PublicSuffixList.parse(String text) {
    final rules = <String>{};
    final wild = <String>{};
    final exc = <String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('//')) continue;
      final rule = line.split(RegExp(r'\s')).first.toLowerCase();
      if (rule.startsWith('!')) {
        exc.add(rule.substring(1));
      } else if (rule.startsWith('*.')) {
        wild.add(rule.substring(2));
      } else {
        rules.add(rule);
      }
    }
    return PublicSuffixList._(rules, wild, exc);
  }

  int get ruleCount => _rules.length + _wildcards.length + _exceptions.length;

  static String normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    while (h.endsWith('.')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  static bool isIpAddress(String host) =>
      host.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);

  /// Публичный суффикс хоста по алгоритму PSL (самое длинное совпадение,
  /// исключения важнее масок, по умолчанию правило «*»).
  String publicSuffix(String host) {
    final labels = normalizeHost(host).split('.');
    for (var i = 0; i < labels.length; i++) {
      final candidate = labels.sublist(i).join('.');
      if (_exceptions.contains(candidate)) {
        return labels.sublist(i + 1).join('.');
      }
      if (_rules.contains(candidate)) return candidate;
      if (i + 1 < labels.length &&
          _wildcards.contains(labels.sublist(i + 1).join('.'))) {
        return candidate;
      }
    }
    return labels.last;
  }

  /// Регистрируемый домен (eTLD+1): `api.deepseek.com` → `deepseek.com`,
  /// `a.b.example.co.uk` → `example.co.uk`, `user.github.io` → `user.github.io`.
  /// Null для IP-адресов, пустых хостов и хостов, которые сами являются
  /// публичным суффиксом.
  String? registrableDomain(String host) {
    final h = normalizeHost(host);
    if (h.isEmpty || isIpAddress(h) || !h.contains('.')) return null;
    final suffix = publicSuffix(h);
    if (suffix == h) return null;
    final hostLabels = h.split('.');
    final n = suffix.split('.').length + 1;
    if (hostLabels.length < n) return null;
    return hostLabels.sublist(hostLabels.length - n).join('.');
  }
}
