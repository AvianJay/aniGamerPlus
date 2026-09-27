import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'all_tab.dart';

const kAnimeTags = [
  '動作',
  '冒險',
  '奇幻',
  '異世界',
  '魔法',
  '超能力',
  '科幻',
  '機甲',
  '校園',
  '喜劇',
  '戀愛',
  '青春',
  '勵志',
  '溫馨',
  '悠閒',
  '料理',
  '親情',
  '感人',
  '運動',
  '競技',
  '偶像',
  '音樂',
  '職場',
  '推理',
  '懸疑',
  '時間穿越',
  '歷史',
  '戰爭',
  '血腥暴力',
  '靈異神怪',
  '黑暗',
  '特攝',
  'BL',
  'GL',
];

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state});
  final AppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  String _tag = '';
  String _sort = 'relevance';

  AppState get state => widget.state;

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _remember() async {
    await state.prefs.rememberSearch(_query);
    if (mounted) setState(() {});
  }

  Future<void> _submit(String query) async {
    final clean = query.trim();
    _search.value = TextEditingValue(
        text: clean, selection: TextSelection.collapsed(offset: clean.length));
    setState(() => _query = clean);
    _focus.unfocus();
    await _remember();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        automaticallyImplyLeading: false,
        title: TextField(
          key: const ValueKey('anime-search'),
          controller: _search,
          focusNode: _focus,
          autofocus: true,
          cursorColor: AgpColors.bahamut,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜尋動畫名稱',
            prefixIcon: const Icon(Icons.search_rounded),
            filled: true,
            fillColor: colors.surfaceContainerHighest,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: const BorderSide(color: AgpColors.bahamut)),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜尋',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                      _focus.requestFocus();
                    },
                  ),
          ),
          onChanged: (value) {
            if (_search.value.composing.isValid &&
                !_search.value.composing.isCollapsed) {
              return;
            }
            setState(() => _query = value.trim());
          },
          onSubmitted: _submit,
        ),
        actions: [
          TextButton(
              style: TextButton.styleFrom(foregroundColor: AgpColors.bahamut),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'))
        ],
      ),
      body: SafeArea(
          top: false,
          // 熱門 / 本季清單可能在這一頁開著的時候才載完: 自己聽 AppState
          // (整個 app 不再因為 AppState 一動就全部重建)
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(children: [
                OutlinedButton.icon(
                  key: const ValueKey('anime-tag-filter'),
                  onPressed: _chooseTag,
                  icon: const Icon(Icons.sell_outlined, size: 18),
                  label: Text(_tag.isEmpty ? '選擇標籤' : _tag),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  key: const ValueKey('anime-sort'),
                  tooltip: '排序方式',
                  initialValue: _sort,
                  onSelected: (value) => setState(() => _sort = value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'relevance', child: Text('最相關')),
                    PopupMenuItem(value: 'popular', child: Text('人氣最高')),
                    PopupMenuItem(value: 'default', child: Text('片單順序')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      const Icon(Icons.sort_rounded, size: 18),
                      const SizedBox(width: 4),
                      Text(switch (_sort) {
                        'popular' => '人氣最高',
                        'default' => '片單順序',
                        _ => '最相關',
                      }),
                      const Icon(Icons.arrow_drop_down_rounded),
                    ]),
                  ),
                ),
              ]),
            ),
            Expanded(
                child: ListenableBuilder(
              listenable: state,
              builder: (context, _) =>
                  _query.isEmpty && _tag.isEmpty && _sort == 'relevance'
                      ? _suggestions()
                      : AllTab(
                          state: state,
                          query: _query,
                          tag: _tag,
                          sort: _sort,
                          searchMode: true,
                          onResultOpened: () {
                            _focus.unfocus();
                            _remember();
                          }),
            )),
          ])),
    );
  }

  Widget _suggestions() {
    final history = state.prefs.searchHistory;
    final hot = state.catalog.hot
        .map((e) => e.title)
        .where((e) => e.isNotEmpty)
        .toSet()
        .take(12)
        .toList();
    final suggestions = hot.isNotEmpty
        ? hot
        : state.catalog.season
            .map((e) => e.title)
            .where((e) => e.isNotEmpty)
            .toSet()
            .take(12)
            .toList();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        const Text('依標籤探索', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final tag in kAnimeTags.take(12))
            ActionChip(
                label: Text(tag), onPressed: () => setState(() => _tag = tag)),
        ]),
        const SizedBox(height: 24),
        Row(children: [
          const Icon(Icons.history_rounded, size: 20),
          const SizedBox(width: 8),
          const Expanded(
              child:
                  Text('最近搜尋', style: TextStyle(fontWeight: FontWeight.w700))),
          if (history.isNotEmpty)
            IconButton(
              tooltip: '清除搜尋紀錄',
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              onPressed: () async {
                await state.prefs.clearSearchHistory();
                if (mounted) setState(() {});
              },
            ),
        ]),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Text('搜尋過的動畫會顯示在這裡',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final query in history)
            InputChip(
              label: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => _submit(query),
              deleteButtonTooltipMessage: '刪除「$query」',
              onDeleted: () async {
                await state.prefs.removeSearch(query);
                if (mounted) setState(() {});
              },
            ),
        ]),
        const SizedBox(height: 28),
        if (suggestions.isNotEmpty) ...[
          Row(children: [
            const Icon(Icons.local_fire_department_outlined, size: 20),
            const SizedBox(width: 8),
            Text(hot.isNotEmpty ? '熱門動畫' : '本季動畫',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final title in suggestions)
              ActionChip(
                label:
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () => _submit(title),
              ),
          ]),
        ],
        if (suggestions.isEmpty && history.isEmpty) ...[
          const SizedBox(height: 36),
          Icon(Icons.manage_search_rounded,
              size: 54, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          const Text('輸入作品名稱，搜尋片庫與動畫瘋片單', textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Future<void> _chooseTag() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
          child: FractionallySizedBox(
        heightFactor: 0.7,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('動畫標籤',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final tag in ['', ...kAnimeTags])
              ChoiceChip(
                label: Text(tag.isEmpty ? '全部' : tag),
                selected: _tag == tag,
                onSelected: (_) => Navigator.of(sheetContext).pop(tag),
              ),
          ]),
        ]),
      )),
    );
    if (picked != null && mounted) setState(() => _tag = picked);
  }
}
