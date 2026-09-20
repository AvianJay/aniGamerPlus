/// 片庫 / 片單的卡片.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/downloads.dart';
import '../state/thumbnails.dart';
import '../theme.dart';
import '../util/format.dart';
import 'common.dart';

/// Comfortable poster widths: two columns on phones, five on a 1280px tablet.
const double kPosterTargetWidth = 200;
const double kPosterGridSpacing = 10;
const double kPosterGridPadding = 16;

/// 封面底下留給標題跟集數那兩行字的高度
const double kPosterCaptionHeight = 68;

/// Shared responsive grid; reserve caption space for larger system text.
SliverGridDelegate posterGridDelegate(double width, {double textScale = 1}) {
  final usable = width - kPosterGridPadding * 2;
  final columns = ((usable + kPosterGridSpacing) /
          (kPosterTargetWidth + kPosterGridSpacing))
      .floor()
      .clamp(2, 8);
  final itemWidth =
      math.max(1.0, (usable - kPosterGridSpacing * (columns - 1)) / columns);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: kPosterGridSpacing,
    mainAxisSpacing: 16,
    // 圖是 3:4, 底下留兩行字的位置 —— 用比例算會在窄螢幕上溢出
    mainAxisExtent:
        itemWidth * 4 / 3 + kPosterCaptionHeight * math.max(1, textScale),
  );
}

/// 直式海報 (片單用, 3:4)
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.cover,
    this.subtitle,
    this.badge,
    this.rank,
    this.onTap,
    this.aspectRatio = 3 / 4,
    this.cache,
    this.sn,
    this.headers,
    this.popularity,
    this.favourite,
    this.onFavourite,
  });

  final String title;
  final String? cover;
  final String? subtitle;
  final String? badge;
  final int? rank;
  final VoidCallback? onTap;
  final double aspectRatio;

  /// 有 cache 才走落盤快取. 給了 sn 的話還會去封面清單查 3:4 主視覺 ——
  /// 這一格是直式的, 塞一張 16:9 的劇照進來會裁掉大半.
  final ThumbnailStore? cache;
  final String? sn;
  final Map<String, String>? headers;
  final String? popularity;
  final bool? favourite;
  final VoidCallback? onFavourite;

  @override
  Widget build(BuildContext context) {
    return Material(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(5),
        elevation: Theme.of(context).brightness == Brightness.light ? 1 : 0,
        shadowColor: const Color(0x26000000),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadiusSmall),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  CoverImage(
                    name: title,
                    url: cover,
                    cache: cache,
                    sn: sn,
                    poster: true,
                    headers: headers,
                    aspectRatio: aspectRatio,
                    radius: 0,
                  ),
                  if (onFavourite != null)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        tooltip: favourite == true ? '取消收藏' : '收藏',
                        onPressed: onFavourite,
                        icon: Icon(
                          favourite == true
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: Colors.white,
                          size: 28,
                          shadows: const [
                            Shadow(color: Colors.black54, blurRadius: 8)
                          ],
                        ),
                      ),
                    ),
                  if (popularity != null && popularity!.isNotEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 22, 8, 6),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black54],
                          ),
                        ),
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              const Icon(Icons.visibility_outlined,
                                  color: Colors.white, size: 14),
                              const SizedBox(width: 4),
                              Flexible(
                                  child: Text(popularity!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 11))),
                            ]),
                      ),
                    ),
                  if (badge != null)
                    Positioned(
                        right: 6,
                        bottom: 6,
                        child: Pill(label: badge!, dense: true)),
                  if (rank != null)
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: const BoxDecoration(
                          color: AgpColors.accent,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(kRadiusSmall),
                            bottomRight: Radius.circular(kRadiusSmall),
                          ),
                        ),
                        child: Text(
                          '${rank!}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1.25),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                            ),
                          ),
                      ])),
            ],
          ),
        ));
  }
}

/// 片庫裡的一集 (橫式縮圖 + 進度條)
class EpisodeCard extends StatelessWidget {
  const EpisodeCard({
    super.key,
    required this.video,
    required this.state,
    this.onTap,
    this.onLongPress,
    this.showAnimeName = true,
    this.detail,
    this.onNext,
  });

  final VideoItem video;
  final AppState state;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showAnimeName;
  final String? detail;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final watched = state.watchTimeOf(video.sn);
    final progress = watched?.progress;
    final local = state.downloads.entryFor(video.sn);
    final offlineFile = state.downloads.localThumb(video.sn);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(kRadiusSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              // 沒有本機縮圖就交給封面快取: 離線時它至少還撈得到上次存的那張,
              // 以前那條路是直接不給 url, 結果離線的片庫整片都是漸層
              CoverImage(
                name: video.displayName,
                file: offlineFile,
                cache: offlineFile == null ? state.thumbnails : null,
                sn: video.sn,
                headers: state.client.authHeaders,
              ),
              if (video.resolution > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Pill(label: '${video.resolution}P', dense: true),
                ),
              if (local != null && local.status == DownloadStatus.done)
                const Positioned(
                  left: 6,
                  top: 6,
                  child: Pill(
                    label: '離線',
                    dense: true,
                    icon: Icons.download_done_rounded,
                    color: Color(0xCC1B7F3B),
                  ),
                )
              else if (local != null && local.status == DownloadStatus.running)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Pill(
                    label: '${(local.progress * 100).round()}%',
                    dense: true,
                    icon: Icons.downloading_rounded,
                    color: const Color(0xCC1B5E8F),
                  ),
                ),
              if (video.streaming)
                const Positioned(
                  left: 6,
                  bottom: 6,
                  child: Pill(
                    label: '邊看邊下載',
                    dense: true,
                    color: AgpColors.accent,
                  ),
                ),
              if (progress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ThinProgress(value: progress),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showAnimeName)
                  Text(video.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                    [episodeLabel(video.episode), if (detail != null) detail!]
                        .join(' · '),
                    key: ValueKey('episode-caption-${video.sn}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            )),
            if (onNext != null)
              IconButton(
                  onPressed: onNext,
                  tooltip: '下一集',
                  icon: const Icon(Icons.skip_next_rounded, size: 23)),
          ]),
        ],
      ),
    );
  }
}

/// 清單式的一列 (觀看紀錄 / 下載管理)
class EpisodeRow extends StatelessWidget {
  const EpisodeRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.cover,
    this.coverFile,
    this.headers,
    this.cache,
    this.sn,
    this.progress,
    this.trailing,
    this.onTap,
    this.footer,
  });

  final String title;
  final String subtitle;
  final String? cover;
  final dynamic coverFile;
  final Map<String, String>? headers;
  final ThumbnailStore? cache;
  final String? sn;
  final double? progress;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 500 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: compact ? 88 : 124,
                child: Stack(
                  children: [
                    CoverImage(
                      name: title,
                      url: cover,
                      file: coverFile,
                      headers: headers,
                      cache: cache,
                      sn: sn,
                    ),
                    if (progress != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ThinProgress(value: progress!),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: compact ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    if (footer != null) ...[const SizedBox(height: 6), footer!],
                    if (compact && trailing != null)
                      Align(alignment: Alignment.centerRight, child: trailing!),
                  ],
                ),
              ),
              if (!compact && trailing != null) trailing!,
            ],
          ),
        ),
      );
    });
  }
}
