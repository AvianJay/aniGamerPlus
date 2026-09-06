/// 手動添加任務 —— 對應 control.html 的 #manualTasks 對話框.
///
/// 送的是 POST /manualTask, 欄位跟 aniGamerPlus.js 的 readManualConfig() 一樣:
/// sn / mode / resolution / classify / thread / danmu / auto_update_danmu / m3u8.
/// (網頁的模板裡其實沒有後面兩個開關, JS 永遠送 false; 手機上補上去比較合理。)
///
/// 這是「叫伺服器去下載」, 跟「下載到這支手機」是兩回事 —— 後者在下載管理裡。
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';

/// value -> 網頁 option 的 data-subtext
const Map<String, String> kManualModes = {
  'single': '本集',
  'latest': '最後一集',
  'all': '全部劇集',
  'largest-sn': '最近上傳',
};

const List<String> kManualResolutions = ['1080', '720', '540', '480', '360'];

/// [initialSn] 有值的話直接帶進去, 從播放頁或作品資訊叫出來時用得到.
Future<void> showManualTaskSheet(
  BuildContext context,
  AppState state, {
  String initialSn = '',
  String initialMode = 'single',
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _ManualTaskSheet(
      state: state,
      initialSn: initialSn,
      initialMode: initialMode,
    ),
  );
}

class _ManualTaskSheet extends StatefulWidget {
  const _ManualTaskSheet({
    required this.state,
    required this.initialSn,
    required this.initialMode,
  });

  final AppState state;
  final String initialSn;
  final String initialMode;

  @override
  State<_ManualTaskSheet> createState() => _ManualTaskSheetState();
}

class _ManualTaskSheetState extends State<_ManualTaskSheet> {
  late final TextEditingController _link =
      TextEditingController(text: widget.initialSn);
  late final TextEditingController _thread = TextEditingController(text: '1');

  late String _mode = kManualModes.containsKey(widget.initialMode)
      ? widget.initialMode
      : 'single';
  late String _resolution = widget.state.prefs.downloadResolution;

  bool _classify = true;
  bool _danmu = true;
  bool _autoUpdateDanmu = false;
  bool _m3u8 = false;
  bool _sending = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    if (!kManualResolutions.contains(_resolution)) _resolution = '1080';
    _loadDefaults();
  }

  @override
  void dispose() {
    _link.dispose();
    _thread.dispose();
    super.dispose();
  }

  /// 網頁版把 config.json 的 multi-thread / classify_bangumi / danmu 當預設值,
  /// 拿不到就照著上面那組寫死的來
  Future<void> _loadDefaults() async {
    try {
      final config = await state.client.config();
      if (!mounted) return;
      final thread = config['multi-thread'];
      final resolution = '${config['download_resolution'] ?? ''}'.replaceAll('P', '');
      setState(() {
        if (thread != null) _thread.text = '$thread';
        if (config['classify_bangumi'] is bool) {
          _classify = config['classify_bangumi'] as bool;
        }
        if (config['danmu'] is bool) _danmu = config['danmu'] as bool;
        if (config['m3u8'] is bool) _m3u8 = config['m3u8'] as bool;
        if (config['auto_update_danmu'] is bool) {
          _autoUpdateDanmu = config['auto_update_danmu'] as bool;
        }
        if (kManualResolutions.contains(resolution)) _resolution = resolution;
      });
    } catch (_) {
      // 讀不到設定不影響送任務, 用預設值就好
    }
  }

  Future<void> _submit() async {
    final sn = snFromInput(_link.text);
    if (sn.isEmpty) {
      toast(context, '請輸入影片連結或 sn。');
      return;
    }

    setState(() => _sending = true);
    try {
      await state.client.manualTask(
        sn: sn,
        mode: _mode,
        resolution: _resolution,
        thread: int.tryParse(_thread.text.trim()) ?? 1,
        classify: _classify,
        danmu: _danmu,
        autoUpdateDanmu: _autoUpdateDanmu,
        m3u8: _m3u8,
      );
      state.queued.add(sn);
      if (!mounted) return;
      Navigator.of(context).pop();
      toast(context, '已交給伺服器下載，去任務監控看進度。');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      toast(context, error.needsLogin ? '需要管理員權限。' : '送出失敗: ${error.message}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      toast(context, '送出失敗: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 6,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 2),
              child: Text(
                '手動添加任務',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                '交給伺服器下載到它的片庫，不是下載到這支手機。',
                style: TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
              ),
            ),
            TextField(
              controller: _link,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '影片連結或 sn',
                hintText: 'https://ani.gamer.com.tw/animeVideo.php?sn=12345',
              ),
            ),
            const SizedBox(height: 18),
            _label('下載模式'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in kManualModes.entries)
                  ChoiceChip(
                    label: Text('${entry.key}（${entry.value}）'),
                    selected: _mode == entry.key,
                    onSelected: (_) => setState(() => _mode = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _label('下載解析度'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final res in kManualResolutions)
                  ChoiceChip(
                    label: Text('${res}P'),
                    selected: _resolution == res,
                    onSelected: (_) => setState(() => _resolution = res),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('建立番劇資料夾', style: TextStyle(fontSize: 14.5)),
              value: _classify,
              onChanged: (value) => setState(() => _classify = value),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('下載彈幕', style: TextStyle(fontSize: 14.5)),
              value: _danmu,
              onChanged: (value) => setState(() => _danmu = value),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('自動更新彈幕', style: TextStyle(fontSize: 14.5)),
              value: _autoUpdateDanmu,
              onChanged: (value) => setState(() => _autoUpdateDanmu = value),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('創建播放清單', style: TextStyle(fontSize: 14.5)),
              value: _m3u8,
              onChanged: (value) => setState(() => _m3u8 = value),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _thread,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '最大并發下載數',
                hintText: '正整數',
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined, size: 18),
              label: Text(_sending ? '送出中…' : '提交'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AgpColors.fgFaint,
          ),
        ),
      );
}
