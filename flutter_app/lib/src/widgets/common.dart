/// 到處都在用的小零件: 封面、區塊標題、空狀態、Toast.
library;

import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme.dart';
import '../util/format.dart';

/// 封面. 抓不到圖就退回片名 hash 出來的漸層 —— 跟網頁版的 artFor() 同一組顏色.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.name,
    this.url,
    this.file,
    this.headers,
    this.aspectRatio = 16 / 9,
    this.radius = kRadiusSmall,
    this.fit = BoxFit.cover,
    this.art = true,
  });

  final String name;
  final String? url;
  final File? file;
  final Map<String, String>? headers;

  /// null = 填滿給的空間, 不自己決定比例. 播放器背後那張劇照就是這樣用的:
  /// 播放區不一定是 16:9, 硬套的話兩邊會露出底下那層漸層.
  final double? aspectRatio;
  final double radius;
  final BoxFit fit;

  /// 抓不到圖時要不要退回片名 hash 的漸層. 播放器背後不要 —— 那裡該是黑的,
  /// 不是一塊有字母的彩色方塊.
  final bool art;

  @override
  Widget build(BuildContext context) {
    final ratio = aspectRatio;
    final content = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (art) ...[
              DecoratedBox(decoration: BoxDecoration(gradient: artFor(name))),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    initials(name),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: const TextStyle(
                      color: Color(0x59FFFFFF),
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ] else
              const ColoredBox(color: Color(0xFF000000)),
            if (file != null)
              Image.file(file!, fit: fit, errorBuilder: _fallback)
            else if (url != null && url!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: url!,
                cacheKey: sha256
                    .convert(utf8.encode(jsonEncode([
                      url,
                      if (headers != null)
                        for (final key in (headers!.keys.toList()..sort()))
                          [key, headers![key]],
                    ])))
                    .toString(),
                fit: fit,
                httpHeaders: headers,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
                fadeInDuration: const Duration(milliseconds: 180),
              ),
          ],
        ));
    return ratio == null ? content : AspectRatio(aspectRatio: ratio, child: content);
  }

  static Widget _fallback(
          BuildContext context, Object error, StackTrace? stack) =>
      const SizedBox.shrink();
}

/// 首頁那種「標題 + 右邊一條連結」的區塊頭
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(16, 22, 16, 10),
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.color
                            ?.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: AgpColors.fgFaint),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 13.5, color: AgpColors.fgFaint),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 18),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// agp-shell.js 的 toast()
void toast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 3200),
    ));
}

/// 進度條 (繼續觀看那條紅線)
class ThinProgress extends StatelessWidget {
  const ThinProgress({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        backgroundColor: const Color(0x33FFFFFF),
        color: AgpColors.accent,
      ),
    );
  }
}

/// 卡片右下角那種小徽章 (1080P / 已下載 / 下載中)
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 6 : 8, vertical: dense ? 2 : 3),
      decoration: BoxDecoration(
        color: color ?? const Color(0xB3000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 11 : 13, color: Colors.white),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 橫向捲的一排卡片
class Rail extends StatelessWidget {
  const Rail({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.height = 190,
    this.itemWidth = 148,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double height;
  final double itemWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: itemCount,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: itemWidth,
          child: itemBuilder(context, index),
        ),
      ),
    );
  }
}
