/// App 偏好設定 —— 這一頁網頁版沒有.
///
/// 全部存在 shared_preferences 的 agp-* 底下, 跟伺服器的 config.json 沒有關係:
/// 那份是「下載器怎麼抓片」, 這一頁是「這支手機怎麼播、怎麼存」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/downloads.dart';
import '../state/prefs.dart';
import '../state/updater.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'watch_page.dart';

const List<String> kResolutionChoices = ['1080', '720', '540', '480', '360'];

class AppPrefsPage extends StatefulWidget {
  const AppPrefsPage({super.key, required this.state});

  final AppState state;

  @override
  State<AppPrefsPage> createState() => _AppPrefsPageState();
}

class _AppPrefsPageState extends State<AppPrefsPage> {
  int _bytes = -1;
  Timer? _measureTimer;
  bool _clearing = false;

  AppState get state => widget.state;
  Prefs get prefs => state.prefs;
  DownloadStore get store => state.downloads;

  @override
  void initState() {
    super.initState();
    _measure();
    _measureCache();
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

  Future<void> _save(Future<void> Function() write) async {
    await state.savePref(write);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App 偏好設定')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          _group('播放'),
          _pick<double>(
            title: '預設播放速度',
            value: prefs.rate,
            label: prefs.rate == 1 ? '正常' : '${prefs.rate}×',
            choices: [
              for (final rate in kPlaybackRates)
                _Opt(rate, rate == 1 ? '正常' : '$rate×'),
            ],
            onPick: (value) => _save(() => prefs.setRate(value)),
          ),
          _pick<String>(
            title: '畫面比例',
            value: prefs.aspect,
            label: _aspectLabel(prefs.aspect),
            choices: [
              for (final mode in kAspectModes) _Opt(mode.value, mode.label),
            ],
            onPick: (value) => _save(() => prefs.setAspect(value)),
          ),
          _pick<int>(
            title: '線上播放畫質',
            value: prefs.playbackResolution,
            label: '${prefs.playbackResolution}P',
            choices: [
              for (final res in kResolutionChoices)
                _Opt(int.parse(res), '${res}P')
            ],
            onPick: (value) => _save(() => prefs.setPlaybackResolution(value)),
          ),
          const ListTile(
            title: Text('螢幕亮度'),
            subtitle: Text('進入播放器時跟隨裝置亮度，播放時可在畫面左側上下滑動調整。'),
          ),
          SwitchListTile(
            title: const Text('自動播放下一集'),
            subtitle: const Text('一集播完之後倒數 8 秒接下一集'),
            value: prefs.autoNext,
            onChanged: (value) => _save(() => prefs.setAutoNext(value)),
          ),
          _group('彈幕'),
          SwitchListTile(
            title: const Text('預設開啟彈幕'),
            value: prefs.danmakuOn,
            onChanged: (value) => _save(() => prefs.setDanmakuOn(value)),
          ),
          _pick<int>(
            title: '透明度',
            value: prefs.danmakuOpacity,
            label: '${prefs.danmakuOpacity}%',
            choices: [for (final o in kDanmakuOpacities) _Opt(o, '$o%')],
            onPick: (value) => _save(() => prefs.setDanmakuOpacity(value)),
          ),
          _pick<double>(
            title: '顯示區域',
            value: prefs.danmakuArea,
            label: _areaLabel(prefs.danmakuArea),
            choices: [
              for (final area in kDanmakuAreas) _Opt(area.value, area.label),
            ],
            onPick: (value) => _save(() => prefs.setDanmakuArea(value)),
          ),
          _pick<double>(
            title: '字級',
            value: prefs.danmakuScale,
            label: _scaleLabel(prefs.danmakuScale),
            choices: [
              for (final scale in kDanmakuScales)
                _Opt(scale.value, scale.label),
            ],
            onPick: (value) => _save(() => prefs.setDanmakuScale(value)),
          ),
          _pick<double>(
            title: '飄過速度',
            value: prefs.danmakuSpeed,
            label: _speedLabel(prefs.danmakuSpeed),
            choices: [
              for (final speed in kDanmakuSpeeds)
                _Opt(speed.value, speed.label),
            ],
            onPick: (value) => _save(() => prefs.setDanmakuSpeed(value)),
          ),
          _group('下載到手機'),
          _pick<String>(
            title: '預設畫質',
            value: prefs.downloadResolution,
            label: '${prefs.downloadResolution}P',
            note: '伺服器片庫裡沒有這個畫質時會退回它手上有的那一份。',
            choices: [
              for (final res in kResolutionChoices) _Opt(res, '${res}P')
            ],
            onPick: (value) => _save(() => prefs.setDownloadResolution(value)),
          ),
          SwitchListTile(
            title: const Text('一起抓彈幕'),
            subtitle: const Text('離線看的時候才有彈幕'),
            value: prefs.downloadDanmaku,
            onChanged: (value) => _save(() => prefs.setDownloadDanmaku(value)),
          ),
          SwitchListTile(
            title: const Text('線上播放先讀本機快取'),
            subtitle: const Text('把每一集的檔頭留在手機上，下次開同一集不必再抓一遍'),
            value: prefs.videoCache,
            onChanged: (value) => _save(() => prefs.setVideoCache(value)),
          ),
          SwitchListTile(
            title: const Text('只在 Wi-Fi 下載'),
            subtitle: const Text('行動網路時佇列會停著等連上 Wi-Fi'),
            value: prefs.downloadWifiOnly,
            onChanged: (value) => _save(() => state.setDownloadWifiOnly(value)),
          ),
          _pick<int>(
            title: '同時下載數',
            value: prefs.downloadConcurrency,
            label: '${prefs.downloadConcurrency} 個',
            choices: const [_Opt(1, '1 個'), _Opt(2, '2 個'), _Opt(3, '3 個')],
            onPick: (value) async {
              store.concurrency = value;
              await _save(() => prefs.setDownloadConcurrency(value));
            },
          ),
          _group('外觀'),
          _pick<String>(
            title: '主題',
            value: prefs.themeMode,
            label: switch (prefs.themeMode) {
              'light' => '淺色',
              'system' => '跟隨系統',
              _ => '深色',
            },
            choices: const [
              _Opt('dark', '深色'),
              _Opt('light', '淺色'),
              _Opt('system', '跟隨系統')
            ],
            onPick: (value) => _save(() => state.setThemeMode(value)),
          ),
          _group('更新'),
          _pick<String>(
            title: '更新通道',
            value: prefs.updateChannel,
            label: UpdateChannel.parse(prefs.updateChannel).label,
            note: 'Nightly 是 master 每次推送的自動建置，可能不穩定。',
            choices: [
              for (final channel in UpdateChannel.values)
                _Opt(channel.key, channel.label),
            ],
            onPick: (value) => _save(() => prefs.setUpdateChannel(value)),
          ),
          SwitchListTile(
            title: const Text('開啟 App 時檢查更新'),
            value: prefs.updateAutoCheck,
            onChanged: (value) => _save(() => prefs.setUpdateAutoCheck(value)),
          ),
          if (Platform.isIOS)
            _pick<String>(
              title: 'iOS 安裝方式',
              value: prefs.iosInstaller,
              label: IosInstaller.parse(prefs.iosInstaller).label,
              note: '沒有裝對應的 App 時會自動改用其他方式。',
              choices: [
                for (final installer in IosInstaller.values)
                  _Opt(installer.key, installer.label),
              ],
              onPick: (value) => _save(() => prefs.setIosInstaller(value)),
            ),
          _group('儲存空間'),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: Text(_bytes < 0 ? '正在計算…' : '離線影片佔用 ${formatBytes(_bytes)}'),
            subtitle: Text('已下載 ${store.finished.length} 集'),
            trailing: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              onPressed: _measure,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(_clearing ? '正在清除…' : '清除播放與片單快取'),
            subtitle: Text(_cacheLabel),
            onTap: _clearing ? null : _clearCache,
          ),
        ],
      ),
    );
  }

  String _cacheLabel = '首頁、片單與線上播放的暫存，不會刪掉已下載的影片';

  Future<void> _measureCache() async {
    final bytes = await state.videoCacheBytes();
    if (!mounted || bytes <= 0) return;
    setState(() => _cacheLabel = '線上播放的暫存目前 ${formatBytes(bytes)}，不會刪掉已下載的影片');
  }

  Future<void> _clearCache() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    try {
      await prefs.clearCache();
      await state.clearVideoCache();
      if (!mounted) return;
      setState(() => _cacheLabel = '首頁、片單與線上播放的暫存，不會刪掉已下載的影片');
      toast(context, '已清除播放與片單快取。');
    } catch (_) {
      if (mounted) toast(context, '暫時無法清除快取，請稍後再試。');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  // ------------------------------------------------------------------ 小零件

  Widget _group(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );

  Widget _pick<T>({
    required String title,
    required T value,
    required String label,
    required List<_Opt<T>> choices,
    required Future<void> Function(T value) onPick,
    String note = '',
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Text(note.isEmpty ? label : '$label · $note'),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () async {
        final picked = await showModalBottomSheet<T>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                for (final option in choices)
                  ListTile(
                    dense: true,
                    title: Text(option.label),
                    trailing: option.value == value
                        ? const Icon(Icons.check_rounded,
                            size: 18, color: AgpColors.accent)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(option.value),
                  ),
                const SizedBox(height: 10),
              ],
            )),
          ),
        );
        if (picked != null && mounted) await onPick(picked);
      },
    );
  }

  String _aspectLabel(String key) {
    for (final mode in kAspectModes) {
      if (mode.value == key) return mode.label;
    }
    return kAspectModes.first.label;
  }

  String _areaLabel(double value) {
    for (final area in kDanmakuAreas) {
      if (area.value == value) return area.label;
    }
    return kDanmakuAreas.first.label;
  }

  String _scaleLabel(double value) {
    for (final scale in kDanmakuScales) {
      if (scale.value == value) return scale.label;
    }
    return '標準';
  }

  String _speedLabel(double value) {
    for (final speed in kDanmakuSpeeds) {
      if (speed.value == value) return speed.label;
    }
    return '標準';
  }
}

class _Opt<T> {
  const _Opt(this.value, this.label);
  final T value;
  final String label;
}
