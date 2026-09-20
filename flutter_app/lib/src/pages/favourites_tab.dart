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
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
              kPosterGridPadding, 16, kPosterGridPadding, 28),
          gridDelegate: posterGridDelegate(constraints.maxWidth,
              textScale: MediaQuery.textScalerOf(context).scale(14) / 14),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final item = list[index];
            final head = _libraryHead(item);
            final episodes = head == null
                ? const <VideoItem>[]
                : state.episodesOf(head.animeName);
            final latest = episodes.isEmpty ? null : episodes.last;

            return PosterCard(
              title: item.name,
              cover: item.cover.isEmpty ? null : item.cover,
              cache: state.thumbnails,
              sn: head?.sn,
              headers: state.client.authHeaders,
              subtitle: latest != null
                  ? '共 ${episodes.length} 集 · 更新至 ${episodeLabel(latest.episode)}'
                  : '片庫沒有這部，點開看作品資訊',
              onTap: () => _open(context, item, latest),
              favourite: true,
              onFavourite: () async {
                await state.toggleFavourite(item);
                if (context.mounted) toast(context, '已從收藏移除');
              },
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
