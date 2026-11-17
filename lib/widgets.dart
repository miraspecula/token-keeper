import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'services.dart';
import 'token_check.dart';

/// Кружок иконки сервиса: кэшированный favicon или буква на цветном фоне.
/// При выключенных иконках — сразу буква, без FutureBuilder, сети и диска.
class FaviconView extends StatelessWidget {
  final ServiceCard card;
  final double size;

  const FaviconView({super.key, required this.card, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppPrefs.faviconsEnabled,
      builder: (context, enabled, _) {
        final domain = card.domain;
        if (!enabled || domain == null) return _fallback();
        return FutureBuilder<File?>(
          future: FaviconService.ensureCached(domain, card.url),
          builder: (context, snap) {
            final file = snap.data;
            if (file != null) {
              return FaviconImage(
                  file: file, size: size, fallback: _fallback());
            }
            return _fallback();
          },
        );
      },
    );
  }

  Widget _fallback() {
    final color = ColorPalette.colorFor(card.colorIndex);
    final fg = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    final letter =
        card.name.trim().isEmpty ? '?' : card.name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      alignment: Alignment.center,
      child: Text(letter,
          style: TextStyle(
              color: fg, fontSize: size * 0.5, fontWeight: FontWeight.w600)),
    );
  }
}

/// Строка списка карточек.
class ServiceTile extends StatelessWidget {
  final ServiceCard card;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  const ServiceTile({
    super.key,
    required this.card,
    required this.onTap,
    required this.onCopy,
    required this.onShare,
  });

  String _two(int n) => n.toString().padLeft(2, '0');

  String _fmtDate(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final masked = card.token.isEmpty
        ? ''
        : '••••••••${card.token.length > 4 ? card.token.substring(card.token.length - 4) : card.token}';

    Widget? badge;
    if (card.isExpired) {
      badge = _Chip(label: 'просрочен', color: scheme.error);
    } else if (card.isExpiringSoon && card.expiry != null) {
      badge = _Chip(
          label: 'истекает ${_fmtDate(card.expiry!)}', color: Colors.orange);
    } else if (card.expiry != null) {
      badge =
          _Chip(label: 'до ${_fmtDate(card.expiry!)}', color: scheme.secondary);
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: ListTile(
        onTap: onTap,
        leading: FaviconView(card: card),
        title: Text(card.name.isEmpty ? 'Без названия' : card.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(masked, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (badge != null) ...[
              const SizedBox(height: 4),
              badge,
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Копировать токен',
              icon: const Icon(Icons.copy_rounded),
              onPressed: onCopy,
            ),
            IconButton(
              tooltip: 'Поделиться',
              icon: const Icon(Icons.ios_share_rounded),
              onPressed: onShare,
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}

/// Картинка из кэша иконок: PNG (растр уже нормализован) или SVG.
class FaviconImage extends StatelessWidget {
  final File file;
  final double size;
  final Widget fallback;

  const FaviconImage(
      {super.key, required this.file, required this.size, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final Widget child = FaviconService.isSvgFile(file)
        ? SvgPicture.file(file,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => fallback)
        : Image.file(file,
            width: size,
            height: size,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => fallback);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 4),
      child: SizedBox(width: size, height: size, child: child),
    );
  }
}

/// Логотип приложения (шайба) для экранов входа и первой настройки.
class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/washer.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'Token Keeper',
      );
}

/// Плашка результата проверки токена.
class CheckResultView extends StatelessWidget {
  final CheckResult result;
  const CheckResultView({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (result.status) {
      CheckStatus.valid => (Icons.check_circle_outline, Colors.green),
      CheckStatus.invalid => (Icons.block, scheme.error),
      CheckStatus.paymentRequired => (Icons.payments_outlined, Colors.orange),
      CheckStatus.rateLimited => (Icons.hourglass_bottom, Colors.orange),
      CheckStatus.noNetwork => (Icons.wifi_off, scheme.outline),
      CheckStatus.unknownService => (Icons.help_outline, scheme.outline),
      CheckStatus.serverError => (Icons.cloud_off, Colors.orange),
      CheckStatus.error => (Icons.error_outline, Colors.orange),
    };
    final lines = [
      if (result.provider != null)
        '${result.provider!.name}${result.provider!.known ? '' : ' (как OpenAI-совместимый API)'}',
      if (result.httpCode != null) 'HTTP ${result.httpCode}',
      ?result.detail,
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.title,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                if (lines.isNotEmpty)
                  Text(lines.join(' · '),
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Компактная кнопка-иконка внутри поля ввода (40×40), чтобы несколько кнопок
/// помещались в узком поле и не наезжали на текст.
class FieldIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const FieldIconButton(
      {super.key, required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      );
}

/// Копирует значение и показывает короткий SnackBar «Скопировано».
/// [secret] — токен: через ClipboardService с автоочисткой через 45 с.
void copyWithFeedback(BuildContext context, String value,
    {bool secret = false}) {
  if (value.isEmpty) return;
  if (secret) {
    ClipboardService.copyToken(value);
  } else {
    Clipboard.setData(ClipboardData(text: value));
  }
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
        content: Text('Скопировано'), duration: Duration(seconds: 2)));
}

/// Кнопка «Копировать» для поля ввода; неактивна, пока поле пустое.
class CopyFieldButton extends StatelessWidget {
  final TextEditingController controller;
  final bool secret;
  const CopyFieldButton(
      {super.key, required this.controller, this.secret = false});

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, v, _) {
          final value = v.text.trim();
          return FieldIconButton(
            icon: Icons.copy_rounded,
            tooltip: 'Копировать',
            onPressed: value.isEmpty
                ? null
                : () => copyWithFeedback(context, value, secret: secret),
          );
        },
      );
}
