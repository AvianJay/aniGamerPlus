/// 片庫 / 片單的卡片.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/downloads.dart';
import '../state/thumbnail_store.dart';
import '../theme.dart';
import '../util/format.dart';
import 'common.dart';
import 'local_thumb.dart';

/// 一格海報大概長這麼寬. 欄數是除出來的, 不是寫死的 —— 寫死 3 欄的話
/// 平板上一張封面會撐到 200 多寬, 像被放大鏡照過.
const double kPosterTargetWidth = 128;
const double kPosterGridSpacing = 10;
const double kPosterGridPadding = 16;

/// 封面底下留給標題跟集數那兩行字的高度
const double kPosterCaptionHeight = 52;

/// 片庫、收藏共用的海報格線. 手機還是 3 欄 (寬度除下來剛好), 平板會自己
/// 長成 5 欄以上, 每一格的寬度維持差不多.
SliverGridDelegate posterGridDelegate(double width) {
  final usable = width - kPosterGridPadding * 2;
  final columns = math.max(3, (usable / kPosterTargetWidth).round());
  final itemWidth =
      math.max(1.0, (usable - kPosterGridSpacing * (columns - 1)) / columns);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: kPosterGridSpacing,
    mainAxisSpacing: 16,
    // 圖是 3:4, 底下留兩行字的位置 —— 用比例算會在窄螢幕上溢出
    mainAxisExtent: itemWidth * 4 / 3 + kPosterCaptionHeight,
  );
}

/// 直式海報 (片單用, 3:4)
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.cover,
    this.coverFile,
    this.thumbSn,
    this.thumbStore,
    this.subtitle,
    this.badge,
    this.rank,
    this.onTap,
    this.aspectRatio = 3 / 4,
  });

  final String title;
  final String? cover;

  /// 已經在手機上的封面 (下載好的那一集附的). 有就先畫它.
  final File? coverFile;

  /// 片庫作品走手機端縮圖快取時設這兩個: 縮圖是手機自己跟巴哈要、
  /// 存在手機上的, 不再走伺服器的 /thumbnail.jpg. 沒設就維持舊行為
  /// (cover 直鏈, 片單那種).
  final String? thumbSn;
  final ThumbnailStore? thumbStore;

  final String? subtitle;
  final String? badge;
  final int? rank;
  final VoidCallback? onTap;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final thumbSn = this.thumbSn;
    final thumbStore = this.thumbStore;
    final useLocalThumb =
        thumbStore != null && thumbSn != null && thumbSn.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              if (useLocalThumb)
                LocalThumb(
                  store: thumbStore!,
                  sn: thumbSn!,
                  name: title,
                  offlineFile: coverFile,
                  aspectRatio: aspectRatio,
                )
              else
                CoverImage(
                    name: title,
                    url: cover,
                    file: coverFile,
                    aspectRatio: aspectRatio),
              if (badge != null)
                Positioned(right: 6, bottom: 6, child: Pill(label: badge!, dense: true)),
              if (rank != null)
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
          const SizedBox(height: 7),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.25),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: AgpColors.fgFaint),
              ),
            ),
        ],
      ),
    );
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
  });

  final VideoItem video;
  final AppState state;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showAnimeName;

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
              LocalThumb(
                store: state.thumbnails,
                sn: video.sn,
                name: video.displayName,
                offlineFile: offlineFile,
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
          if (showAnimeName)
            Text(
              video.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              episodeLabel(video.episode),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AgpColors.fgFaint),
            ),
          ),
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
    this.thumbSn,
    this.thumbStore,
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

  /// 片庫集數走手機端縮圖快取時設這兩個 (見 PosterCard.thumbSn).
  final String? thumbSn;
  final ThumbnailStore? thumbStore;

  final double? progress;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 124,
              child: Stack(
                children: [
                  if (thumbStore != null &&
                      thumbSn != null &&
                      thumbSn!.isNotEmpty)
                    LocalThumb(
                      store: thumbStore!,
                      sn: thumbSn!,
                      name: title,
                      offlineFile: coverFile is File ? coverFile as File : null,
                    )
                  else
                    CoverImage(
                      name: title,
                      url: cover,
                      file: coverFile is File ? coverFile as File : null,
                      headers: headers,
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
                  ),
                  if (footer != null) ...[const SizedBox(height: 6), footer!],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
