/// 收藏 —— 存在手機本機, 跟網頁版的 localStorage 是同一份資料結構.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../util/format.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import 'anime_sheet.dart';
import 'watch_page.dart';

class FavouritesTab extends StatelessWidget {
  const FavouritesTab({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final list = state.favourites;
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.favorite_outline,
        title: '還沒有收藏任何作品',
        message: '在作品資訊或播放頁按下「收藏」，作品就會留在這裡。',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        const spacing = 10.0;
        final itemWidth =
            (constraints.maxWidth - 32 - spacing * (columns - 1)) / columns;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: spacing,
            mainAxisSpacing: 16,
            mainAxisExtent: itemWidth * 4 / 3 + 52,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final item = list[index];
            final head = _libraryHead(item);
            final episodes =
                head == null ? const <VideoItem>[] : state.episodesOf(head.animeName);
            final latest = episodes.isEmpty ? null : episodes.last;

            return Stack(
              children: [
                PosterCard(
                  title: item.name,
                  cover: head != null && !state.offline
                      ? state.client.thumbnailUrl(head.sn).toString()
                      : (item.cover.isEmpty ? null : item.cover),
                  subtitle: latest != null
                      ? '共 ${episodes.length} 集 · 更新至 ${episodeLabel(latest.episode)}'
                      : '片庫沒有這部，點開看作品資訊',
                  onTap: () => _open(context, item, latest),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () async {
                      await state.toggleFavourite(item);
                      if (context.mounted) toast(context, '已從收藏移除');
                    },
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Color(0xB3000000),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  VideoItem? _libraryHead(Favourite item) {
    for (final video in state.animeHeads) {
      if (item.matches(video.animeName, video.title)) return video;
    }
    return null;
  }

  void _open(BuildContext context, Favourite item, VideoItem? latest) {
    if (latest != null) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WatchPage(state: state, sn: latest.sn),
      ));
      return;
    }
    showAnimeSheet(
      context,
      state,
      videoSn: item.sn,
      title: item.name,
      cover: item.cover,
    );
  }
}
