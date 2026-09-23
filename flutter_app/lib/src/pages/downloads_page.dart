/// 手機下載管理 —— 網頁版沒有的一頁.
///
/// 佇列裡的每一集都是一支對 /get_video.mp4 的 Range 請求, 暫停就是把連線切掉,
/// 續傳靠 .part 的長度接回去. 下載完的集數在首頁跟播放器都會自動改讀本機檔.
library;

import 'dart:async';

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
  Timer? _measureTimer;
  int _filter = 0;
  bool _retrying = false;
  bool _bulkBusy = false;

  AppState get state => widget.state;
  DownloadStore get store => state.downloads;

  @override
  void initState() {
    super.initState();
    _measure();
    store.addListener(_onDownloadsChanged);
  }

  @override
  void dispose() {
    store.removeListener(_onDownloadsChanged);
    _measureTimer?.cancel();
    super.dispose();
  }

  void _onDownloadsChanged() {
    _measureTimer ??= Timer(const Duration(milliseconds: 500), () {
      _measureTimer = null;
      if (mounted) unawaited(_measure());
    });
  }

  Future<void> _measure() async {
    final bytes = await store.totalBytesOnDisk();
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  /// 手動再問一次伺服器要彈幕.
  ///
  /// 自動那條路有冷卻時間 (免得每次開 app 都把伺服器問一遍), 使用者自己按的
  /// 時候就不必等 —— force 直接跳過冷卻.
  Future<void> _retryDanmaku() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    final before = store.danmakuPending.length;
    toast(context, '正在向伺服器要 $before 集的彈幕…');
    await store.retryMissingDanmaku(force: true);
    if (!mounted) return;
    setState(() => _retrying = false);
    final after = store.danmakuPending.length;
    toast(
      context,
      after == 0
          ? '彈幕都補齊了。'
          : before == after
              ? '伺服器還沒生出這些彈幕，等一下再試。'
              : '補到 ${before - after} 集，還有 $after 集要等。',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 連上線 / 斷線 (state.offline) 會改到上面那顆補抓彈幕
      listenable: Listenable.merge([store, state]),
      builder: (context, _) {
        final active = store.active;
        final finished = store.finished;
        final busy = active.any((e) =>
            e.status == DownloadStatus.running ||
            e.status == DownloadStatus.queued ||
            e.status == DownloadStatus.waiting);
        final missingDanmaku = store.danmakuPending.length;

        return Scaffold(
          appBar: AppBar(
            title: const Text('離線下載'),
            actions: [
              if (missingDanmaku > 0 && !state.offline && store.networkAllowed)
                IconButton(
                  tooltip: '補抓彈幕 ($missingDanmaku 集)',
                  icon: const Icon(Icons.comment_outlined),
                  onPressed: _retrying ? null : _retryDanmaku,
                ),
              if (active.isNotEmpty)
                IconButton(
                  tooltip: busy ? '全部暫停' : '全部繼續',
                  icon: Icon(
                      busy ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: _bulkBusy
                      ? null
                      : () async {
                          setState(() => _bulkBusy = true);
                          try {
                            if (busy) {
                              await store.pauseAll();
                            } else {
                              await store.resumeAll();
                            }
                          } catch (_) {
                            if (context.mounted) {
                              toast(context, '無法更新下載佇列，請稍後重試。');
                            }
                          } finally {
                            if (mounted) setState(() => _bulkBusy = false);
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
                  message: '在作品資訊長按集數，選「下載單集到手機」就會排進來。離線時照樣看得到。',
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 28),
                  children: [
                    _summary(active, finished),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final item in [
                          (0, '全部'),
                          (1, '佇列 ${active.length}'),
                          (2, '已完成 ${finished.length}')
                        ])
                          ChoiceChip(
                              label: Text(item.$2),
                              selected: _filter == item.$1,
                              onSelected: (_) =>
                                  setState(() => _filter = item.$1)),
                      ]),
                    ),
                    if (!store.networkAllowed)
                      const ListTile(
                        leading: Icon(Icons.wifi_off_rounded),
                        title: Text('等待 Wi-Fi'),
                        subtitle: Text('連上 Wi-Fi 後會自動繼續；手動暫停的項目會維持暫停。'),
                      ),
                    if (_filter != 2 && active.isNotEmpty) ...[
                      const SectionHeader(title: '佇列中'),
                      for (final entry in active) _row(entry),
                    ],
                    if (_filter != 1 && finished.isNotEmpty) ...[
                      SectionHeader(
                        title: '已下載',
                        subtitle: '${finished.length} 集',
                      ),
                      for (final entry in finished) _row(entry),
                    ],
                    if ((_filter == 1 && active.isEmpty) ||
                        (_filter == 2 && finished.isEmpty))
                      Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(_filter == 1 ? '目前沒有排隊的下載' : '還沒有已完成的下載',
                              textAlign: TextAlign.center)),
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
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          children: [
            const Icon(Icons.sd_storage_outlined,
                size: 18, color: AgpColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _bytes < 0
                    ? '正在計算佔用空間…'
                    : '佔用 ${formatBytes(_bytes)} · 已下載 ${finished.length} 集 · 佇列 ${active.length} 集',
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
      cache: store.localThumb(entry.sn) == null ? state.thumbnails : null,
      sn: entry.sn,
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
                // 等伺服器的那段沒有進度可言, 給一條不動的底線比跑馬燈誠實
                value: entry.status != DownloadStatus.running
                    ? 0
                    : entry.total > 0
                        ? entry.progress
                        : null,
                minHeight: 4,
                backgroundColor: const Color(0x1FFFFFFF),
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.status == DownloadStatus.running ||
              entry.status == DownloadStatus.queued ||
              entry.status == DownloadStatus.waiting)
            IconButton(
              tooltip: entry.status == DownloadStatus.waiting ? '取消等待' : '暫停',
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
        final danmaku = entry.hasDanmaku
            ? ' · 含彈幕'
            : entry.wantDanmaku
                ? ' · 彈幕等待中'
                : '';
        return '$res已下載 · ${formatBytes(entry.total)}$danmaku';
      case DownloadStatus.running:
        return entry.total > 0
            ? '$res下載中 ${(entry.progress * 100).round()}% · $size'
            : '$res下載中 · $size';
      case DownloadStatus.queued:
        return store.networkAllowed ? '$res排隊中' : '$res等待 Wi-Fi · $size';
      case DownloadStatus.waiting:
        return '$res等待伺服器下載完成';
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
    try {
      await store.remove(entry.sn);
      await _measure();
      if (mounted) toast(context, '已從這支手機刪除。');
    } catch (_) {
      if (mounted) toast(context, '刪除失敗，請稍後再試。');
    }
  }
}
