/// 「檢查更新」與「有新版」對話框.
///
/// [checkForUpdates] 兩種用法: 「我的」頁手動按 (什麼結果都要說), 以及開 App
/// 時靜靜地看一眼 (silent: 沒新版、連不上、被略過的版本都不出聲).
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../state/prefs.dart';
import '../state/updater.dart';
import '../util/format.dart';
import '../widgets/common.dart';

Future<void> checkForUpdates(BuildContext context, Prefs prefs,
    {bool silent = false}) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  final channel = UpdateChannel.parse(prefs.updateChannel);
  final updater = Updater();
  try {
    final current = await Updater.current();
    final UpdateInfo? info;
    try {
      info = await updater.check(channel,
          ios: Platform.isIOS, currentBuild: current.build);
    } on UpdateException catch (e) {
      if (!silent && context.mounted) toast(context, e.message);
      return;
    }
    if (!context.mounted) return;
    if (info == null) {
      if (!silent) toast(context, '已是最新版本（${channel.label} · $current）。');
      return;
    }
    if (silent && prefs.skippedUpdateBuild == info.build) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(
        updater: updater,
        prefs: prefs,
        info: info!,
        current: current,
      ),
    );
  } finally {
    updater.close();
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.updater,
    required this.prefs,
    required this.info,
    required this.current,
  });

  final Updater updater;
  final Prefs prefs;
  final UpdateInfo info;
  final AppVersion current;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  int _received = 0;
  int _total = -1;
  String _error = '';

  UpdateInfo get info => widget.info;

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = '';
      _received = 0;
      _total = -1;
    });
    try {
      if (Platform.isIOS) {
        final used = await Updater.installIpa(
            info, IosInstaller.parse(widget.prefs.iosInstaller));
        if (!mounted) return;
        toast(context,
            used == null ? '已用瀏覽器開啟 IPA 下載。' : '已交給 ${used.label} 安裝。');
        Navigator.of(context).pop();
        return;
      }
      final apk =
          await widget.updater.downloadApk(info, onProgress: (received, total) {
        if (mounted) {
          setState(() {
            _received = received;
            _total = total;
          });
        }
      });
      await Updater.installApk(apk);
      if (mounted) Navigator.of(context).pop();
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '更新失敗，請稍後再試。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip() async {
    await widget.prefs.setSkippedUpdateBuild(info.build);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final commit =
        info.commit.length > 7 ? info.commit.substring(0, 7) : info.commit;
    return AlertDialog(
      title: Text('有新版本（${info.channel.label}）'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.current} → ${info.label}'),
            if (commit.isNotEmpty || info.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                [
                  if (commit.isNotEmpty) commit,
                  if (info.notes.isNotEmpty) info.notes
                ].join(' · '),
                style: TextStyle(fontSize: 12.5, color: muted),
              ),
            ],
            if (Platform.isIOS) ...[
              const SizedBox(height: 8),
              Text(
                '會把 IPA 交給 TrollStore / SideStore / AltStore 安裝，'
                '都沒有裝的話改用瀏覽器下載。',
                style: TextStyle(fontSize: 12.5, color: muted),
              ),
            ],
            if (_busy && Platform.isAndroid) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(
                  value: _total > 0 ? _received / _total : null),
              const SizedBox(height: 6),
              Text(
                _total > 0
                    ? '${formatBytes(_received)} / ${formatBytes(_total)}'
                    : formatBytes(_received),
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_error,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _skip,
          child: const Text('略過這版'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('稍後'),
        ),
        FilledButton(
          onPressed: _busy ? null : _install,
          child: Text(_error.isEmpty ? '更新' : '重試'),
        ),
      ],
    );
  }
}
