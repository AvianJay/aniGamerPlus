/// 網頁控制台 —— 對應 control.html 的「網頁控制台」那一區.
///
/// POST /console/command {"command": "..."}. 伺服器成功回 200 {success,message},
/// 失敗回 400 帶同樣的 message (client 會丟 ApiException), help 另外帶 commands.
/// 輸出的前綴跟 aniGamerPlus.js 一致: `> 指令` / `[成功] ` / `[失敗] `。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 網頁上那三顆快捷鍵, 再加一顆 reload-config (指令本來就有)
const List<List<String>> _quickCommands = [
  ['checknow', '立即更新'],
  ['update-videolist', '立即更新影片清單'],
  ['reload-config', '重載配置'],
  ['help', '指令說明'],
];

class ConsoleLine {
  const ConsoleLine(this.text, this.kind);

  /// echo / ok / fail / plain
  final String text;
  final String kind;
}

class ConsolePage extends StatefulWidget {
  const ConsolePage({super.key, required this.state});

  final AppState state;

  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final List<ConsoleLine> _lines = [];

  bool _running = false;

  AppState get state => widget.state;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _append(String text, [String kind = 'plain']) {
    if (!mounted) return;
    setState(() => _lines.add(ConsoleLine(text, kind)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _run([String? command]) async {
    final cmd = (command ?? _input.text).trim();
    if (cmd.isEmpty) {
      _append('[錯誤] 請輸入指令', 'fail');
      return;
    }
    if (_running) return;

    _append('> $cmd', 'echo');
    _input.clear();
    setState(() => _running = true);

    try {
      final result = await state.client.consoleCommand(cmd);
      if (result['help'] == true) {
        _append(_formatHelp(result['commands']), 'plain');
      } else {
        final ok = result['success'] == true;
        _append('${ok ? '[成功] ' : '[失敗] '}${result['message'] ?? ''}',
            ok ? 'ok' : 'fail');
      }
    } on ApiException catch (error) {
      _append(
        '[失敗] ${error.needsLogin ? '需要管理員權限' : error.message}',
        'fail',
      );
    } catch (error) {
      _append('[失敗] 指令執行失敗: $error', 'fail');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String _formatHelp(dynamic commands) {
    if (commands is! List || commands.isEmpty) return '沒有可用指令';
    final lines = <String>['可用指令:'];
    for (final item in commands) {
      if (item is! Map) continue;
      lines.add('- ${item['name'] ?? ''} : ${item['help'] ?? ''}');
    }
    return lines.join('\n');
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('網頁控制台'),
        actions: [
          IconButton(
            tooltip: '清空輸出',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _lines.isEmpty ? null : () => setState(_lines.clear),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: [
                for (final quick in _quickCommands)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(quick[1]),
                      onPressed: _running ? null : () => _run(quick[0]),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _output()),
          _bar(),
        ],
      ),
    );
  }

  Widget _output() {
    if (_lines.isEmpty) {
      return const EmptyState(
        icon: Icons.terminal_rounded,
        title: '指令輸出',
        message: '打 help 看得到伺服器認得哪些指令，上面幾顆是常用的。',
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AgpColors.bgElev,
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: AgpColors.line),
      ),
      child: ListView.builder(
        controller: _scroll,
        itemCount: _lines.length,
        itemBuilder: (context, index) {
          final line = _lines[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SelectableText(
              line.text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontFamily: 'monospace',
                color: _colourOf(line.kind),
              ),
            ),
          );
        },
      ),
    );
  }

  Color _colourOf(String kind) {
    switch (kind) {
      case 'echo':
        return AgpColors.fgFaint;
      case 'ok':
        return const Color(0xFF34D399);
      case 'fail':
        return AgpColors.accent;
      default:
        return AgpColors.fgDim;
    }
  }

  Widget _bar() {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.send,
              inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
              style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'help...',
                isDense: true,
              ),
              onSubmitted: (_) {
                _run();
                _focus.requestFocus();
              },
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _running ? null : () => _run(),
            child: _running
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('執行'),
          ),
        ],
      ),
    );
  }
}
