/// 線上編輯 sn_list —— 對應 control.html 的 #snList 對話框.
///
/// 讀 GET /data/sn_list, 存 POST /sn_list (text/plain, 整份覆蓋).
/// 手機上打這種格式很痛苦, 所以多了「貼連結加一行」跟格式說明, 存的東西一樣。
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';

/// sn_list-sample.txt 的欄位說明
const List<List<String>> _formatHelp = [
  ['10147 all # 前進吧！登山少女', '最基本的一行: sn、下載模式、井號後面是註解'],
  ['11317 latest # SSSS.GRIDMAN', 'latest 只追最新一集，all 是整部'],
  ['11285 <史萊姆> # 關於我轉生…', '角括號裡是自訂資料夾名'],
  ['@2019冬季番', '@ 開頭是分組標題，@ 單獨一行結束分組'],
];

class SnListPage extends StatefulWidget {
  const SnListPage({super.key, required this.state});

  final AppState state;

  @override
  State<SnListPage> createState() => _SnListPageState();
}

class _SnListPageState extends State<SnListPage> {
  final TextEditingController _editor = TextEditingController();

  String _original = '';
  bool _loading = true;
  bool _saving = false;
  String _error = '';

  AppState get state => widget.state;

  bool get _dirty => _editor.text != _original;

  @override
  void initState() {
    super.initState();
    _editor.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final text = await state.client.snList();
      if (!mounted) return;
      setState(() {
        _original = text;
        _editor.text = text;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.needsLogin ? '需要管理員權限。' : error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '讀不到 sn_list: $error';
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await state.client.saveSnList(_editor.text);
      if (!mounted) return;
      setState(() {
        _original = _editor.text;
        _saving = false;
      });
      toast(context, 'sn_list 已儲存。');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, '儲存失敗: $error');
    }
  }

  // ------------------------------------------------------------------ 加一行

  Future<void> _appendLine() async {
    final link = TextEditingController();
    final note = TextEditingController();
    var mode = 'latest';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 6,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  '加一行到 sn_list',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              TextField(
                controller: link,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '影片連結或 sn',
                  hintText: 'https://ani.gamer.com.tw/animeVideo.php?sn=12345',
                ),
              ),
              const SizedBox(height: 14),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'latest', label: Text('最新一集')),
                  ButtonSegment(value: 'all', label: Text('全部劇集')),
                  ButtonSegment(value: 'largest-sn', label: Text('最近上傳')),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setSheetState(() => mode = selection.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: note,
                decoration: const InputDecoration(
                  labelText: '註解',
                  helperText: '寫在井號後面，只是給人看的',
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('加進去'),
              ),
            ],
          ),
        ),
      ),
    );

    final sn = snFromInput(link.text.trim());
    final comment = note.text.trim();
    link.dispose();
    note.dispose();
    if (ok != true) return;
    if (sn.isEmpty) {
      if (mounted) toast(context, '看不出這是哪一個 sn。');
      return;
    }

    final line = comment.isEmpty ? '$sn $mode' : '$sn $mode # $comment';
    final current = _editor.text;
    final next = current.isEmpty
        ? line
        : (current.endsWith('\n') ? '$current$line' : '$current\n$line');
    _editor.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  Future<void> _showFormat() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'sn_list 格式',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                '一行一部作品，伺服器每次檢查更新時從上往下跑一遍。',
                style: TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
              ),
              const SizedBox(height: 14),
              for (final row in _formatHelp)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: BoxDecoration(
                          color: AgpColors.bgElev,
                          borderRadius: BorderRadius.circular(kRadiusSmall),
                          border: Border.all(color: AgpColors.line),
                        ),
                        child: Text(
                          row[0],
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        row[1],
                        style: const TextStyle(
                            fontSize: 12, color: AgpColors.fgDim),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final lines = _editor.text.isEmpty
        ? 0
        : _editor.text
            .split('\n')
            .where((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'))
            .length;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final yes = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('還沒儲存'),
            content: const Text('離開就會丟掉剛剛改的內容。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('離開'),
              ),
            ],
          ),
        );
        if (yes == true && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('sn_list'),
          actions: [
            IconButton(
              tooltip: '格式說明',
              icon: const Icon(Icons.help_outline_rounded),
              onPressed: _showFormat,
            ),
            IconButton(
              tooltip: '重新讀取',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loading || _saving ? null : _load,
            ),
            const SizedBox(width: 4),
          ],
        ),
        floatingActionButton: _loading || _error.isNotEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: _appendLine,
                icon: const Icon(Icons.playlist_add_rounded),
                label: const Text('加一行'),
              ),
        bottomNavigationBar: _loading || _error.isNotEmpty
            ? null
            : SafeArea(
                minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _dirty ? '$lines 部作品 · 有還沒儲存的修改' : '$lines 部作品',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _dirty ? AgpColors.accent : AgpColors.fgFaint,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _saving || !_dirty ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded, size: 18),
                      label: Text(_saving ? '儲存中…' : '儲存'),
                    ),
                    const SizedBox(width: 92),
                  ],
                ),
              ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return EmptyState(
        icon: Icons.list_alt_rounded,
        title: '讀不到 sn_list',
        message: _error,
        actionLabel: '重試',
        onAction: _load,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: AgpColors.bgElev,
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.line),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: TextField(
          controller: _editor,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace', height: 1.6),
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintText: '10147 all # 前進吧！登山少女',
            isDense: true,
          ),
        ),
      ),
    );
  }
}
