/// 用戶管理 —— 對應 templates/usermanage.html.
///
/// 網頁那張表格在手機上永遠是橫向捲軸, 這裡改成一列一張卡, 編輯走 sheet.
/// 送出的還是同一支 POST /usermanage (add / change / delete).
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';

/// 伺服器回的是英文, 手機上翻一次比較好讀
const Map<String, String> _messages = {
  'User created': '已新增用戶',
  'User updated': '已更新用戶',
  'User deleted': '已刪除用戶',
  'User not found': '找不到這個用戶',
  'User already exists': '這個帳號已經有人用了',
  'Cannot delete current user': '不能刪掉自己',
  'Username and password are required': '帳號跟初始密碼都要填',
  'Invalid action': '伺服器不認得這個操作',
};

String _say(String raw) => _messages[raw] ?? raw;

class UserManagePage extends StatefulWidget {
  const UserManagePage({super.key, required this.state});

  final AppState state;

  @override
  State<UserManagePage> createState() => _UserManagePageState();
}

class _UserManagePageState extends State<UserManagePage> {
  List<ManagedUser> _users = const [];
  bool _loading = true;
  String _error = '';

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final users = await state.client.users();
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.needsLogin ? '需要管理員權限。' : error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '拿不到用戶清單，伺服器回的東西看不懂。';
      });
    }
  }

  Future<bool> _send(
    String action, {
    required String username,
    String? password,
    String? role,
  }) async {
    try {
      final message = await state.client
          .manageUser(action, username: username, password: password, role: role);
      if (!mounted) return true;
      toast(context, _say(message));
    } on ApiException catch (error) {
      if (!mounted) return false;
      toast(context, _say(error.message));
      return false;
    } catch (error) {
      if (!mounted) return false;
      toast(context, '操作失敗: $error');
      return false;
    }
    await _load();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('用戶管理'),
        actions: [
          IconButton(
            tooltip: '重新整理',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addUser,
        icon: const Icon(Icons.person_add_alt_rounded),
        label: const Text('新增用戶'),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        title: '讀不到用戶清單',
        message: _error,
        actionLabel: '重試',
        onAction: _load,
      );
    }
    if (_users.isEmpty) {
      return const EmptyState(
        icon: Icons.group_outlined,
        title: '還沒有任何用戶',
        message: '按右下角新增第一個帳號。',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 90),
        itemCount: _users.length,
        separatorBuilder: (_, __) => const Divider(indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final user = _users[index];
          final me = state.currentUser?.username.toLowerCase() ==
              user.username.toLowerCase();
          return ListTile(
            leading: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: artFor(user.username),
                shape: BoxShape.circle,
              ),
              child: Text(
                user.username.isEmpty
                    ? '?'
                    : user.username.substring(0, 1).toUpperCase(),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    user.username,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (me) ...[
                  const SizedBox(width: 6),
                  const Pill(label: '你', dense: true, color: AgpColors.accent),
                ],
              ],
            ),
            subtitle: Text(
              '${user.isAdmin ? '管理員' : '一般用戶'} · 觀看紀錄 ${user.videoTimes} 筆',
              style: const TextStyle(fontSize: 12.5),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => _editUser(user, isSelf: me),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------ 新增

  Future<void> _addUser() async {
    final username = TextEditingController();
    final password = TextEditingController();
    var role = 'user';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  '新增用戶',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              TextField(
                controller: username,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '使用者名稱'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '初始密碼'),
              ),
              const SizedBox(height: 14),
              _RolePicker(
                value: role,
                onChanged: (value) => setSheetState(() => role = value),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('新增'),
              ),
            ],
          ),
        ),
      ),
    );

    final name = username.text.trim();
    final pw = password.text;
    username.dispose();
    password.dispose();
    if (ok != true) return;
    if (name.isEmpty || pw.isEmpty) {
      if (mounted) toast(context, '請輸入使用者名稱與初始密碼。');
      return;
    }
    await _send('add', username: name, password: pw, role: role);
  }

  // ------------------------------------------------------------------ 編輯

  Future<void> _editUser(ManagedUser user, {required bool isSelf}) async {
    final password = TextEditingController();
    var role = user.role;

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  user.username,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  '觀看紀錄 ${user.videoTimes} 筆',
                  style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
                ),
              ),
              _RolePicker(
                value: role,
                onChanged: (value) => setSheetState(() => role = value),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '新密碼',
                  helperText: '留空表示不變更',
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop('change'),
                child: const Text('儲存'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: isSelf
                    ? null
                    : () => Navigator.of(sheetContext).pop('delete'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isSelf ? null : AgpColors.accent,
                ),
                child: Text(isSelf ? '不能刪掉自己' : '刪除這個用戶'),
              ),
            ],
          ),
        ),
      ),
    );

    final pw = password.text;
    password.dispose();
    if (action == null) return;

    if (action == 'change') {
      await _send(
        'change',
        username: user.username,
        role: role,
        password: pw.isEmpty ? null : pw,
      );
      return;
    }

    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('確定要刪除用戶 ${user.username} 嗎？'),
        content: const Text('連同這個帳號的觀看紀錄一起消失，救不回來。'),
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
    if (yes == true) await _send('delete', username: user.username);
  }
}

class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.value, required this.onChanged});

  final String value;
  final void Function(String value) onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'user', label: Text('一般用戶'), icon: Icon(Icons.person_outline)),
        ButtonSegment(
            value: 'admin', label: Text('管理員'), icon: Icon(Icons.shield_outlined)),
      ],
      selected: {value == 'admin' ? 'admin' : 'user'},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
