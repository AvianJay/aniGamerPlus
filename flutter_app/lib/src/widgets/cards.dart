/// 片庫 / 片單的卡片.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/downloads.dart';
import '../theme.dart';
import '../util/format.dart';
import 'common.dart';

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
  });

  final String title;
  final String? cover;
  final String? subtitle;
  final String? badge;
  final int? rank;
  final VoidCallback? onTap;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              CoverImage(name: title, url: cover, aspectRatio: aspectRatio),
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
              CoverImage(
                name: video.displayName,
                file: offlineFile,
                url: offlineFile == null && !state.offline
                    ? state.client.thumbnailUrl(video.sn).toString()
                    : null,
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
                  CoverImage(
                    name: title,
                    url: cover,
                    file: coverFile,
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
