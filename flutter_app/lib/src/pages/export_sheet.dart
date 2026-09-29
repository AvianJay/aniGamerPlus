/// 匯出影片檔 —— 把下載到手機的集數存到 App 外面.
///
/// 挑集數、要不要附彈幕是這裡的事; 存到哪裡交給系統的選擇器 (Android 的
/// 儲存位置選擇器、iOS 的檔案 App), 所以不必跟使用者要任何儲存空間權限.
library;

import 'package:file_export/file_export.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/downloads.dart';
import '../state/video_export.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';

/// [only] 有給就只匯出那一集 (下載列表那顆按鈕、作品資訊的集數選單);
/// 沒給就列出所有下載好的集數讓使用者挑.
Future<void> showExportSheet(
  BuildContext context,
  DownloadStore store, {
  String? only,
}) async {
  final candidates = only == null
      ? store.finished
      : [
          if (store.entryFor(only) case final entry? when entry.playable) entry,
        ];
  if (candidates.isEmpty) {
    toast(context, only == null ? '還沒有下載好的集數。' : '這一集還沒下載好。');
    return;
  }
  final single = only != null;
  final choice = await showModalBottomSheet<_ExportChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) {
      final sheet = _ExportSheet(candidates: candidates, single: single);
      return single
          ? sheet
          : FractionallySizedBox(heightFactor: 0.9, child: sheet);
    },
  );
  if (choice == null || !context.mounted) return;
  await exportEpisodes(context, store, choice.entries,
      withDanmaku: choice.withDanmaku);
}

/// 交給系統選位置, 選好之後 (只有 Android 回報得出來) 顯示複製進度.
Future<void> exportEpisodes(
  BuildContext context,
  DownloadStore store,
  List<DownloadEntry> entries, {
  required bool withDanmaku,
}) async {
  final files = exportFilesFor(store, entries, withDanmaku: withDanmaku);
  if (files.isEmpty) {
    toast(context, '找不到這些集數的影片檔，可能已經被刪掉了。');
    return;
  }
  final episodes = files.where((file) => file.mimeType == 'video/mp4').length;
  final navigator = Navigator.of(context);
  final progress = ValueNotifier<(int, int)>((0, 0));
  DialogRoute<void>? dialog;
  String? message;
  try {
    final result = await FileExport.save(files, onProgress: (copied, total) {
      progress.value = (copied, total);
      // 第一次回報進度就代表使用者選好位置了, 這時候才把對話框擺出來
      if (dialog != null || !context.mounted) return;
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ExportProgressDialog(progress: progress),
      );
      dialog = route;
      navigator.push(route);
    });
    if (result.cancelled) {
      // 在選擇器裡按取消就是不想存了, 不必再多說什麼
      if (dialog != null) {
        message =
            result.saved > 0 ? '已停止匯出，先存好的 ${result.saved} 個檔案會保留。' : '已取消匯出。';
      }
    } else if (result.saved >= files.length) {
      message =
          episodes == 1 ? '已匯出「${files.first.name}」。' : '已匯出 $episodes 集。';
    } else {
      message = '只匯出了 ${result.saved}/${files.length} 個檔案。';
    }
  } on PlatformException catch (error) {
    final details = error.details;
    final saved = details is Map ? (details['saved'] as num?)?.toInt() ?? 0 : 0;
    message = error.code == 'busy'
        ? '上一個匯出還沒結束。'
        : '匯出失敗：${error.message ?? error.code}'
            '${saved > 0 ? '（已存好 $saved 個檔案）' : ''}';
  } on MissingPluginException {
    message = '這個平台不支援匯出。';
  } finally {
    final route = dialog;
    if (route != null && route.isActive) navigator.removeRoute(route);
    progress.dispose();
  }
  if (message != null && context.mounted) toast(context, message);
}

class _ExportChoice {
  const _ExportChoice(this.entries, this.withDanmaku);

  final List<DownloadEntry> entries;
  final bool withDanmaku;
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.candidates, required this.single});

  final List<DownloadEntry> candidates;
  final bool single;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late final Set<String> _picked = {
    if (widget.single) widget.candidates.first.sn,
  };
  bool _danmaku = true;

  /// 同一部作品排在一起, 集數照數字排; 作品之間照最近下載的先
  late final List<(String, List<DownloadEntry>)> _groups = () {
    final groups = <String, List<DownloadEntry>>{};
    for (final entry in widget.candidates) {
      groups.putIfAbsent(entry.displayName, () => []).add(entry);
    }
    return [
      for (final group in groups.entries)
        (group.key, group.value..sort(_byEpisode)),
    ];
  }();

  /// 勾起來的集數, 照畫面上的順序 —— 存出去的順序也就是使用者看到的順序
  List<DownloadEntry> get _chosen => [
        for (final (_, entries) in _groups)
          for (final entry in entries)
            if (_picked.contains(entry.sn)) entry,
      ];

  bool get _anyDanmaku => widget.candidates.any((e) => e.hasDanmaku);

  static int _byEpisode(DownloadEntry a, DownloadEntry b) {
    final x = double.tryParse(a.episode.trim());
    final y = double.tryParse(b.episode.trim());
    if (x != null && y != null) return x.compareTo(y);
    if (x != null) return -1;
    if (y != null) return 1;
    return a.episode.compareTo(b.episode);
  }

  void _confirm() {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    Navigator.of(context).pop(_ExportChoice(chosen, _danmaku));
  }

  TextStyle get _dim => TextStyle(
      fontSize: 12.5,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant);

  @override
  Widget build(BuildContext context) {
    return widget.single ? _buildSingle() : _buildMany();
  }

  Widget _header() {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '匯出影片檔',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          tooltip: '關閉',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }

  Widget _danmakuSwitch({EdgeInsets? padding}) {
    return SwitchListTile(
      contentPadding: padding,
      value: _danmaku,
      onChanged: (value) => setState(() => _danmaku = value),
      title: const Text('附上彈幕字幕檔'),
      subtitle: const Text('.ass 跟影片同名，VLC、mpv 等播放器會自動載入'),
    );
  }

  /// Android 一次存好幾個檔案是請使用者選資料夾, 而那個選擇器有它的脾氣
  Widget? _folderHint() {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    final chosen = _chosen;
    final count = chosen.length +
        (_danmaku ? chosen.where((e) => e.hasDanmaku).length : 0);
    if (count < 2) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        '接下來會請你選一個資料夾，檔案會一起存進去。'
        '「Download」本身不能直接選，可以先在裡面新增一個資料夾。',
        style: _dim,
      ),
    );
  }

  Widget _buildSingle() {
    final entry = widget.candidates.first;
    final res = entry.resolution > 0 ? '${entry.resolution}P · ' : '';
    final name = '${exportBaseName(entry)}.mp4';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            Text(
              '${entry.displayName} · ${episodeLabel(entry.episode)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('$res${formatBytes(entry.total)}', style: _dim),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(kRadiusSmall),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Row(
                children: [
                  const Icon(Icons.movie_outlined,
                      size: 18, color: AgpColors.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(name, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
            if (entry.hasDanmaku) ...[
              const SizedBox(height: 4),
              _danmakuSwitch(padding: EdgeInsets.zero),
            ],
            const SizedBox(height: 8),
            if (_folderHint() case final hint?) hint,
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _confirm,
                icon: const Icon(Icons.save_alt_rounded, size: 18),
                label: const Text('選擇儲存位置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMany() {
    final chosen = _chosen;
    final bytes = chosen.fold<int>(0, (sum, e) => sum + e.total);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 6, 0),
          child: _header(),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              TextButton(
                onPressed: _picked.length == widget.candidates.length
                    ? null
                    : () => setState(() => _picked
                      ..clear()
                      ..addAll(widget.candidates.map((e) => e.sn))),
                child: const Text('全選'),
              ),
              TextButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () => setState(() => _picked.clear()),
                child: const Text('全不選'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              if (_anyDanmaku)
                _danmakuSwitch(
                    padding: const EdgeInsets.symmetric(horizontal: 18)),
              for (final (name, entries) in _groups) ...[
                _groupHeader(name, entries),
                for (final entry in entries) _episodeTile(entry),
              ],
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          decoration: BoxDecoration(
            border:
                Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_folderHint() case final hint?) hint,
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: chosen.isEmpty ? null : _confirm,
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                    label: Text(chosen.isEmpty
                        ? '選一些集數'
                        : '匯出 ${chosen.length} 集 · ${formatBytes(bytes)}'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _groupHeader(String name, List<DownloadEntry> entries) {
    final on = entries.where((e) => _picked.contains(e.sn)).length;
    return CheckboxListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18),
      controlAffinity: ListTileControlAffinity.leading,
      tristate: true,
      value: on == 0 ? false : (on == entries.length ? true : null),
      onChanged: (_) => setState(() {
        if (on == entries.length) {
          _picked.removeAll(entries.map((e) => e.sn));
        } else {
          _picked.addAll(entries.map((e) => e.sn));
        }
      }),
      title: Text(
        name,
        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      ),
      subtitle: Text('${entries.length} 集'),
    );
  }

  Widget _episodeTile(DownloadEntry entry) {
    final res = entry.resolution > 0 ? '${entry.resolution}P · ' : '';
    final danmaku = entry.hasDanmaku ? ' · 含彈幕' : '';
    return CheckboxListTile(
      contentPadding: const EdgeInsets.only(left: 42, right: 18),
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      value: _picked.contains(entry.sn),
      onChanged: (value) => setState(() {
        if (value == true) {
          _picked.add(entry.sn);
        } else {
          _picked.remove(entry.sn);
        }
      }),
      title: Text(episodeLabel(entry.episode)),
      subtitle: Text('$res${formatBytes(entry.total)}$danmaku'),
    );
  }
}

class _ExportProgressDialog extends StatefulWidget {
  const _ExportProgressDialog({required this.progress});

  final ValueListenable<(int, int)> progress;

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  bool _stopping = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 複製跑到一半不能用返回鍵關掉 —— 關掉了也停不下來, 只是看不到而已
      canPop: false,
      child: AlertDialog(
        title: const Text('正在匯出…'),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: widget.progress,
          builder: (context, value, _) {
            final (copied, total) = value;
            final ratio = total > 0 ? (copied / total).clamp(0.0, 1.0) : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: ratio, minHeight: 6),
                ),
                const SizedBox(height: 12),
                Text(
                  ratio == null
                      ? '準備中…'
                      : '${formatBytes(copied)} / ${formatBytes(total)} · '
                          '${(ratio * 100).round()}%',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: _stopping
                ? null
                : () {
                    setState(() => _stopping = true);
                    FileExport.cancel().ignore();
                  },
            child: Text(_stopping ? '正在停止…' : '取消'),
          ),
        ],
      ),
    );
  }
}
