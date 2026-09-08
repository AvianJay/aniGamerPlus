/// App 偏好設定 —— 這一頁網頁版沒有.
///
/// 全部存在 shared_preferences 的 agp-* 底下, 跟伺服器的 config.json 沒有關係:
/// 那份是「下載器怎麼抓片」, 這一頁是「這支手機怎麼播、怎麼存」。
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/downloads.dart';
import '../state/prefs.dart';
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

  AppState get state => widget.state;
  Prefs get prefs => state.prefs;
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
            title: '預設畫面亮度',
            value: (prefs.brightness * 100).round(),
            label: '${(prefs.brightness * 100).round()}%',
            note: '播放器把畫面本身調暗，不會動到裝置的螢幕亮度。',
            choices: [for (final level in kBrightnessLevels) _Opt(level, '$level%')],
            onPick: (value) => _save(() => prefs.setBrightness(value / 100)),
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
              for (final scale in kDanmakuScales) _Opt(scale.value, scale.label),
            ],
            onPick: (value) => _save(() => prefs.setDanmakuScale(value)),
          ),
          _pick<double>(
            title: '飄過速度',
            value: prefs.danmakuSpeed,
            label: _speedLabel(prefs.danmakuSpeed),
            choices: [
              for (final speed in kDanmakuSpeeds) _Opt(speed.value, speed.label),
            ],
            onPick: (value) => _save(() => prefs.setDanmakuSpeed(value)),
          ),

          _group('下載到手機'),
          _pick<String>(
            title: '預設畫質',
            value: prefs.downloadResolution,
            label: '${prefs.downloadResolution}P',
            note: '伺服器片庫裡沒有這個畫質時會退回它手上有的那一份。',
            choices: [for (final res in kResolutionChoices) _Opt(res, '${res}P')],
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
            onChanged: (value) => _save(() => prefs.setDownloadWifiOnly(value)),
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
          ListTile(
            title: const Text('主題'),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'dark', label: Text('深色')),
                ButtonSegment(value: 'light', label: Text('淺色')),
                ButtonSegment(value: 'system', label: Text('跟隨系統')),
              ],
              // SegmentedButton 收到不在 segments 裡的值會直接 assert,
              // 舊版本存過別的字串時不該讓設定頁整個開不起來
              selected: {
                const {'dark', 'light', 'system'}.contains(prefs.themeMode)
                    ? prefs.themeMode
                    : 'dark',
              },
              showSelectedIcon: false,
              onSelectionChanged: (selection) async {
                await state.setThemeMode(selection.first);
                if (mounted) setState(() {});
              },
            ),
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
            title: const Text('清除離線快取'),
            subtitle: const Text('首頁與片單的離線副本，不會刪掉已下載的影片'),
            onTap: _clearCache,
          ),
        ],
      ),
    );
  }

  Future<void> _clearCache() async {
    await prefs.clearCache();
    if (!mounted) return;
    toast(context, '已清除離線快取。');
  }

  // ------------------------------------------------------------------ 小零件

  Widget _group(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AgpColors.fgFaint,
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
      subtitle: note.isEmpty ? null : Text(note),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12.8, color: AgpColors.fgFaint)),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
      onTap: () async {
        final picked = await showModalBottomSheet<T>(
          context: context,
          builder: (sheetContext) => SafeArea(
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
            ),
          ),
        );
        if (picked != null) await onPick(picked);
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
