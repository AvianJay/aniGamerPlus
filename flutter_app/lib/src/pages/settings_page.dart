/// 伺服器設定 —— 對應 templates/control.html + static/js/aniGamerPlus.js.
///
/// 網頁那一頁是一大片 bootstrap 開關擠在一起, 手機上改成分區的卡片.
/// 欄位跟網頁完全一樣 (30 個), 讀 /data/config.json, 寫 /uploadConfig.
///
/// 兩個地方要跟 aniGamerPlus.js 對齊, 不然存回去伺服器會看不懂:
///   * proxy 在 config.json 裡是一整條 `protocol://[user:pw@]ip:port`,
///     畫面上拆成五格, 存檔前再併回去。
///   * browser_fingerprint 是 {"ja3": ..., "akamai": ...}, 同樣拆兩格再併回去。
/// 其餘沒出現在這一頁的鍵 (ftp / plugins / dashboard / telebot ...) 原封不動
/// 帶回去, uploadConfig 收的是整份設定, 少一個鍵就等於把它清掉。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

const List<String> kServerResolutions = ['1080', '720', '540', '480', '360'];
const List<String> kProxyProtocols = ['SOCKS5', 'SOCKS5H', 'HTTP', 'HTTPS'];

/// value -> 網頁 option 的 data-subtext
const Map<String, String> kDownloadModes = {
  'latest': '最後一集',
  'all': '全部劇集',
  'largest-sn': '最近上傳',
};

/// 純文字欄位 (含拆出來的 proxy / 指紋子欄位)
const List<String> _textKeys = [
  'bangumi_dir',
  'temp_dir',
  'customized_video_filename_prefix',
  'customized_video_filename_suffix',
  'ua',
  'browser_fingerprint_ja3',
  'browser_fingerprint_akamai',
  'proxy_ip',
  'proxy_port',
  'proxy_user',
  'proxy_passwd',
];

/// 數字欄位, 存回去要是 int (網頁那邊是 Number())
const List<String> _numberKeys = [
  'check_frequency',
  'multi-thread',
  'multi_downloading_segment',
  'download_cd',
  'parse_sn_cd',
  'quantity_of_logs',
];

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, TextEditingController> _fields = {};

  Map<String, dynamic> _config = {};
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _showPassword = false;
  String _error = '';

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    for (final key in [..._textKeys, ..._numberKeys]) {
      final controller = TextEditingController();
      controller.addListener(_markDirty);
      _fields[key] = controller;
    }
    _load();
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (_dirty || _loading) return;
    setState(() => _dirty = true);
  }

  // ------------------------------------------------------------------ 讀寫

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final config = await state.client.config();
      if (!mounted) return;
      _config = config;
      _spread(config);
      setState(() {
        _loading = false;
        _dirty = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.needsLogin ? '需要管理員權限才能看設定。' : error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '讀不到設定: $error';
      });
    }
  }

  /// config.json -> 畫面上的欄位
  void _spread(Map<String, dynamic> config) {
    String text(String key) {
      final value = config[key];
      if (value == null) return '';
      return '$value';
    }

    for (final key in _textKeys) {
      if (key.startsWith('proxy_') || key.startsWith('browser_fingerprint_')) {
        continue;
      }
      _fields[key]!.text = text(key);
    }
    for (final key in _numberKeys) {
      _fields[key]!.text = text(key);
    }

    final fingerprint = config['browser_fingerprint'];
    final ja3 = fingerprint is Map ? '${fingerprint['ja3'] ?? ''}' : '';
    final akamai = fingerprint is Map ? '${fingerprint['akamai'] ?? ''}' : '';
    _fields['browser_fingerprint_ja3']!.text = ja3;
    _fields['browser_fingerprint_akamai']!.text = akamai;

    _spreadProxy(text('proxy'));

    // download_resolution 在 config.json 裡沒有 P, 網頁的 select 才有
    final resolution = text('download_resolution').replaceAll('P', '');
    _config['download_resolution'] =
        kServerResolutions.contains(resolution) ? resolution : '1080';

    final mode = text('default_download_mode');
    _config['default_download_mode'] =
        kDownloadModes.containsKey(mode) ? mode : 'latest';
  }

  /// aniGamerPlus.js 的 parseProxy(): `protocol://[user:pw@]ip:port`
  void _spreadProxy(String raw) {
    var protocol = 'HTTP';
    var host = '';
    var port = '';
    var user = '';
    var password = '';

    var rest = raw.trim();
    final scheme = rest.indexOf('://');
    if (scheme >= 0) {
      protocol = rest.substring(0, scheme).toUpperCase();
      rest = rest.substring(scheme + 3);
    }
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      final credentials = rest.substring(0, at);
      rest = rest.substring(at + 1);
      final colon = credentials.indexOf(':');
      if (colon >= 0) {
        user = credentials.substring(0, colon);
        password = credentials.substring(colon + 1);
      } else {
        user = credentials;
      }
    }
    final colon = rest.lastIndexOf(':');
    if (colon >= 0) {
      host = rest.substring(0, colon);
      port = rest.substring(colon + 1);
    } else {
      host = rest;
    }

    _fields['proxy_ip']!.text = host;
    _fields['proxy_port']!.text = port;
    _fields['proxy_user']!.text = user;
    _fields['proxy_passwd']!.text = password;
    _config['proxy_protocol'] =
        kProxyProtocols.contains(protocol) ? protocol : 'HTTP';
  }

  /// 畫面上的欄位 -> 送回伺服器的整份 config.json
  Map<String, dynamic> _collect() {
    final out = Map<String, dynamic>.from(_config);

    for (final key in _textKeys) {
      if (key.startsWith('proxy_') || key.startsWith('browser_fingerprint_')) {
        continue;
      }
      out[key] = _fields[key]!.text;
    }
    for (final key in _numberKeys) {
      out[key] = int.tryParse(_fields[key]!.text.trim()) ?? 0;
    }

    out['browser_fingerprint'] = {
      'ja3': _fields['browser_fingerprint_ja3']!.text.trim(),
      'akamai': _fields['browser_fingerprint_akamai']!.text.trim(),
    };

    final host = _fields['proxy_ip']!.text.trim();
    final port = _fields['proxy_port']!.text.trim();
    final user = _fields['proxy_user']!.text;
    final password = _fields['proxy_passwd']!.text;
    final protocol = '${out['proxy_protocol'] ?? 'HTTP'}'.toLowerCase();
    if (host.isEmpty && port.isEmpty) {
      // 網頁版這時會存成 `http://:`, 手機上乾脆留空, 伺服器兩種都當作沒設代理
      out['proxy'] = '';
    } else if (user.isEmpty || password.isEmpty) {
      out['proxy'] = '$protocol://$host:$port';
    } else {
      out['proxy'] = '$protocol://$user:$password@$host:$port';
    }

    // 這五個只是畫面上的拆解, config.json 裡沒有這些鍵
    out.remove('proxy_protocol');
    out.remove('proxy_ip');
    out.remove('proxy_port');
    out.remove('proxy_user');
    out.remove('proxy_passwd');
    return out;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await state.client.uploadConfig(_collect());
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      toast(context, '設定已儲存。');
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, error.needsLogin ? '需要管理員權限。' : '儲存失敗: ${error.message}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, '儲存失敗: $error');
    }
  }

  Future<void> _reload() async {
    if (_dirty) {
      final yes = await _confirmDiscard('重載會丟掉還沒儲存的修改，要繼續嗎？', '重載');
      if (yes != true) return;
    }
    await _load();
  }

  Future<bool?> _confirmDiscard(String message, String action) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('還有沒儲存的修改'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final yes = await _confirmDiscard('離開這一頁就會丟掉還沒儲存的修改。', '離開');
        if (yes == true && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('伺服器設定'),
          actions: [
            IconButton(
              tooltip: '重載配置',
              icon: const Icon(Icons.restore_rounded),
              onPressed: _loading || _saving ? null : _reload,
            ),
            const SizedBox(width: 4),
          ],
        ),
        bottomNavigationBar: _loading || _error.isNotEmpty ? null : _saveBar(),
        body: _body(),
      ),
    );
  }

  Widget _saveBar() {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _dirty ? '有還沒儲存的修改' : '設定與伺服器一致',
              style: TextStyle(
                fontSize: 12.5,
                color: _dirty ? AgpColors.accent : AgpColors.fgFaint,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_rounded, size: 18),
            label: Text(_saving ? '儲存中…' : '儲存'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return EmptyState(
        icon: Icons.settings_suggest_outlined,
        title: '讀不到伺服器設定',
        message: _error,
        actionLabel: '重試',
        onAction: _load,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      children: [
        _group('路徑設定', [
          _text('bangumi_dir', '下載目錄', hint: '放空則存放於程式所在資料夾'),
          _text('temp_dir', '暫存目錄', hint: '放空則存放於程式所在資料夾'),
        ]),
        _group('下載設定', [
          _choice(
            key: 'download_resolution',
            title: '下載解析度',
            values: kServerResolutions,
            labelOf: (value) => '${value}P',
          ),
          _choice(
            key: 'default_download_mode',
            title: '默認下載模式',
            values: kDownloadModes.keys.toList(),
            labelOf: (value) => '$value（${kDownloadModes[value]}）',
          ),
          _switch('classify_bangumi', '建立番劇資料夾', '每一部作品各自一個目錄'),
          _switch('lock_resolution', '鎖定解析度', '沒有指定的畫質就宣告下載失敗，不退而求其次'),
          _switch('segment_download_mode', '分段下載模式', '關掉改由 ffmpeg 直接下載'),
          _switch('add_bangumi_name_to_video_filename', '檔名添加番劇名', null),
          _switch('add_resolution_to_video_filename', '檔名添加解析度', null),
          _switch('use_mobile_api', '模擬手機端解析', '解析失敗時可以試試看'),
          _switch('danmu', '下載彈幕', '存成同名的 .ass'),
          _switch('m3u8', '創建播放清單', null),
          _number('check_frequency', '更新間隔', suffix: '分鐘', min: 1),
          _number('multi-thread', '最大并發下載數', suffix: '個', min: 1),
          _number('multi_downloading_segment', '最大并發分段數', suffix: '段', min: 1),
          _number('download_cd', '下載冷卻時間', suffix: '秒'),
          _number('parse_sn_cd', 'SN 解析冷卻時間', suffix: '秒', min: 3),
          _text('customized_video_filename_prefix', '影片檔名前綴'),
          _text('customized_video_filename_suffix', '影片檔名後綴'),
          _text(
            'ua',
            '請求 UA',
            hint: '若有使用 cookie 請與取得 cookie 的瀏覽器保持一致',
            maxLines: 2,
          ),
          _text('browser_fingerprint_ja3', 'JA3 指紋',
              hint: '手動填入 JA3 指紋字串', maxLines: 2),
          _text('browser_fingerprint_akamai', 'Akamai 指紋',
              hint: '手動填入 Akamai 指紋字串', maxLines: 2),
        ]),
        _group('代理設定', [
          _switch('use_proxy', '代理總開關', '關掉的話下面幾格只是留著'),
          _choice(
            key: 'proxy_protocol',
            title: '協議',
            values: kProxyProtocols,
            labelOf: (value) => value,
          ),
          _text('proxy_ip', '伺服器 IP', hint: '127.0.0.1'),
          _number('proxy_port', 'Port', hint: '1080', asText: true),
          _text('proxy_user', '用戶名', hint: '沒有放空即可'),
          _text('proxy_passwd', '密碼', hint: '沒有放空即可', password: true),
        ]),
        _group('其他', [
          _switch('check_latest_version', '啟動時檢查更新', null),
          _switch('read_sn_list_when_checking_update', '每次檢查讀取 sn_list', null),
          _switch('read_config_when_checking_update', '每次檢查讀取配置', null),
          _switch('auto_update_danmu', '自動更新彈幕', '每次檢查更新時把舊集數的彈幕重抓一次'),
          _switch('save_logs', '記錄日志', null),
          _number('quantity_of_logs', '日志數量', suffix: '天', min: 1),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 18, 4, 0),
          child: Text(
            '這一頁改的是伺服器上的 config.json，跟這支手機怎麼播放、下載無關；'
            '那些在「App 偏好設定」裡。',
            style: TextStyle(fontSize: 12, color: AgpColors.fgFaint, height: 1.5),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 小零件

  Widget _group(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AgpColors.fgFaint,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.circular(kRadius),
              border: Border.all(color: AgpColors.line),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _switch(String key, String title, String? subtitle) {
    return SwitchListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14.5)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: _config[key] == true,
      onChanged: (value) => setState(() {
        _config[key] = value;
        _dirty = true;
      }),
    );
  }

  Widget _text(
    String key,
    String label, {
    String hint = '',
    int maxLines = 1,
    bool password = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: TextField(
        controller: _fields[key],
        maxLines: password ? 1 : maxLines,
        obscureText: password && !_showPassword,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          isDense: true,
          suffixIcon: password
              ? IconButton(
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                )
              : null,
        ),
      ),
    );
  }

  Widget _number(
    String key,
    String label, {
    String suffix = '',
    String hint = '',
    int min = 0,
    bool asText = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: TextField(
        controller: _fields[key],
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          isDense: true,
          suffixText: suffix.isEmpty ? null : suffix,
          helperText: asText || min <= 0 ? null : '最小 $min',
        ),
      ),
    );
  }

  Widget _choice({
    required String key,
    required String title,
    required List<String> values,
    required String Function(String value) labelOf,
  }) {
    final current = '${_config[key] ?? values.first}';
    return ListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14.5)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            labelOf(values.contains(current) ? current : values.first),
            style: const TextStyle(fontSize: 12.8, color: AgpColors.fgFaint),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
      onTap: () async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                for (final value in values)
                  ListTile(
                    dense: true,
                    title: Text(labelOf(value)),
                    trailing: value == current
                        ? const Icon(Icons.check_rounded,
                            size: 18, color: AgpColors.accent)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(value),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
        if (picked == null) return;
        setState(() {
          _config[key] = picked;
          _dirty = true;
        });
      },
    );
  }
}
