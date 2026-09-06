/// 手機下載管理 —— 網頁版沒有的一頁.
///
/// 佇列裡的每一集都是一支對 /get_video.mp4 的 Range 請求, 暫停就是把連線切掉,
/// 續傳靠 .part 的長度接回去. 下載完的集數在首頁跟播放器都會自動改讀本機檔.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/downloads.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import 'watch_page.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.state});

  final AppState state;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  int _bytes = -1;

  AppState get state => widget.state;
  DownloadStore get store => state.downloads;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final bytes = await store.totalBytesOnDisk();
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final active = store.active;
        final finished = store.finished;
        final busy = active.any((e) =>
            e.status == DownloadStatus.running || e.status == DownloadStatus.queued);

        return Scaffold(
          appBar: AppBar(
            title: const Text('下載管理'),
            actions: [
              if (active.isNotEmpty)
                IconButton(
                  tooltip: busy ? '全部暫停' : '全部繼續',
                  icon: Icon(busy ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: () async {
                    if (busy) {
                      await store.pauseAll();
                    } else {
                      await store.resumeAll();
                    }
                  },
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: (active.isEmpty && finished.isEmpty)
              ? const EmptyState(
                  icon: Icons.download_outlined,
                  title: '還沒有下載到這支手機的集數',
                  message: '在作品資訊或片庫卡片長按，選「下載到手機」就會排進來。離線時照樣看得到。',
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 28),
                  children: [
                    _summary(active, finished),
                    if (active.isNotEmpty) ...[
                      const SectionHeader(title: '佇列中'),
                      for (final entry in active) _row(entry),
                    ],
                    if (finished.isNotEmpty) ...[
                      SectionHeader(
                        title: '已下載',
                        subtitle: '${finished.length} 集',
                      ),
                      for (final entry in finished) _row(entry),
                    ],
                  ],
                ),
        );
      },
    );
  }

  Widget _summary(List<DownloadEntry> active, List<DownloadEntry> finished) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.line),
        ),
        child: Row(
          children: [
            const Icon(Icons.sd_storage_outlined, size: 18, color: AgpColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _bytes < 0
                    ? '正在計算佔用空間…'
                    : '佔用 ${formatBytes(_bytes)} · 已下載 ${finished.length} 集 · 佇列 ${active.length} 集',
                style: const TextStyle(fontSize: 13, color: AgpColors.fgDim),
              ),
            ),
            IconButton(
              tooltip: '重新計算',
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: _measure,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(DownloadEntry entry) {
    final label = _statusLabel(entry);
    return EpisodeRow(
      title: '${entry.displayName} · ${episodeLabel(entry.episode)}',
      subtitle: label,
      coverFile: store.localThumb(entry.sn),
      cover: state.offline ? null : state.client.thumbnailUrl(entry.sn).toString(),
      headers: state.client.authHeaders,
      progress: entry.status == DownloadStatus.done ? null : entry.progress,
      onTap: entry.playable
          ? () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => WatchPage(state: state, sn: entry.sn),
              ))
          : null,
      footer: entry.status == DownloadStatus.done
          ? null
          : ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: entry.total > 0 ? entry.progress : null,
                minHeight: 4,
                backgroundColor: const Color(0x1FFFFFFF),
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.status == DownloadStatus.running ||
              entry.status == DownloadStatus.queued)
            IconButton(
              tooltip: '暫停',
              icon: const Icon(Icons.pause_rounded, size: 20),
              onPressed: () => store.pause(entry.sn),
            )
          else if (entry.status == DownloadStatus.paused)
            IconButton(
              tooltip: '繼續',
              icon: const Icon(Icons.play_arrow_rounded, size: 22),
              onPressed: () => store.resume(entry.sn),
            )
          else if (entry.status == DownloadStatus.failed)
            IconButton(
              tooltip: '重試',
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: () => store.resume(entry.sn),
            ),
          IconButton(
            tooltip: '刪除',
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: () => _confirmDelete(entry),
          ),
        ],
      ),
    );
  }

  String _statusLabel(DownloadEntry entry) {
    final size = entry.total > 0
        ? '${formatBytes(entry.received)} / ${formatBytes(entry.total)}'
        : formatBytes(entry.received);
    final res = entry.resolution > 0 ? '${entry.resolution}P · ' : '';
    switch (entry.status) {
      case DownloadStatus.done:
        return '$res已下載 · ${formatBytes(entry.total)}${entry.hasDanmaku ? ' · 含彈幕' : ''}';
      case DownloadStatus.running:
        return '$res下載中 ${(entry.progress * 100).round()}% · $size';
      case DownloadStatus.queued:
        return '$res排隊中';
      case DownloadStatus.paused:
        return '$res已暫停 · $size';
      case DownloadStatus.failed:
        return '下載失敗: ${entry.error.isEmpty ? '未知原因' : entry.error}';
    }
  }

  Future<void> _confirmDelete(DownloadEntry entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('要刪掉這一集嗎？'),
        content: Text(
          entry.status == DownloadStatus.done
              ? '${entry.displayName} ${episodeLabel(entry.episode)} 的離線檔案會從這支手機上刪除，伺服器上的片庫不受影響。'
              : '會停止下載並刪掉已經抓到的部分，伺服器上的片庫不受影響。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await store.remove(entry.sn);
    await _measure();
    if (mounted) toast(context, '已從這支手機刪除。');
  }
}
