/// 「我的」—— 網頁版 paneMine 的帳號卡與那排入口, 再加上手機才有的幾項
/// (下載管理、播放偏好、伺服器位址).
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'app_prefs_page.dart';
import 'console_page.dart';
import 'downloads_page.dart';
import 'login_page.dart';
import 'manual_task_sheet.dart';
import 'monitor_page.dart';
import 'register_page.dart';
import 'settings_page.dart';
import 'setup_page.dart';
import 'sn_list_page.dart';
import 'user_info_page.dart';
import 'user_manage_page.dart';

class MeTab extends StatelessWidget {
  const MeTab({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        _card(context),
        if (state.serverInfo.userControl && !state.loggedIn) ...[
          _group('帳號'),
          _tile(
            context,
            icon: Icons.login_rounded,
            title: '登入',
            subtitle: '登入後觀看紀錄與收藏才跟著帳號走',
            page: () => LoginPage(state: state),
          ),
          if (state.serverInfo.allowRegister)
            _tile(
              context,
              icon: Icons.person_add_alt_rounded,
              title: '註冊',
              page: () => RegisterPage(state: state),
            ),
        ],
        if (state.loggedIn) ...[
          _group('帳號'),
          _tile(
            context,
            icon: Icons.badge_outlined,
            title: '帳號資訊',
            subtitle: '修改密碼',
            page: () => UserInfoPage(state: state),
          ),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text('登出'),
            onTap: () => _logout(context),
          ),
        ],
        _group('手機'),
        _tile(
          context,
          icon: Icons.download_rounded,
          title: '下載管理',
          subtitle: '存在這支手機上的集數',
          page: () => DownloadsPage(state: state),
        ),
        _tile(
          context,
          icon: Icons.tune_rounded,
          title: 'App 偏好設定',
          subtitle: '播放、彈幕、下載與外觀',
          page: () => AppPrefsPage(state: state),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('伺服器位址'),
          subtitle: Text(
            state.client.hasServer ? state.client.baseUrl : '尚未設定',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded, size: 20),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SetupPage(state: state, canPop: true),
          )),
        ),
        if (state.canManage) ...[
          _group('管理'),
          _tile(
            context,
            icon: Icons.settings_outlined,
            title: '主控台',
            subtitle: '下載器設定',
            page: () => SettingsPage(state: state),
          ),
          _tile(
            context,
            icon: Icons.list_alt_rounded,
            title: '追番清單',
            subtitle: 'sn_list',
            page: () => SnListPage(state: state),
          ),
          _tile(
            context,
            icon: Icons.monitor_heart_outlined,
            title: '下載監控',
            subtitle: '伺服器現在正在下載什麼',
            page: () => MonitorPage(state: state),
          ),
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('手動下載'),
            subtitle: const Text('貼上動畫瘋連結或 sn'),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => showManualTaskSheet(context, state),
          ),
          _tile(
            context,
            icon: Icons.terminal_rounded,
            title: '命令列',
            subtitle: 'checknow / update-videolist',
            page: () => ConsolePage(state: state),
          ),
          if (state.isAdmin)
            _tile(
              context,
              icon: Icons.group_outlined,
              title: '用戶管理',
              page: () => UserManagePage(state: state),
            ),
        ],
        _group('關於'),
        ListTile(
          leading: const Icon(Icons.refresh_rounded),
          title: const Text('重新整理'),
          subtitle: Text(
            state.offline
                ? (state.lastError.isEmpty ? '連不上伺服器' : state.lastError)
                : '重新抓一次片庫與片單',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () async {
            await state.refreshAll();
            if (context.mounted) {
              toast(context, state.offline ? '還是連不上伺服器。' : '已重新整理。');
            }
          },
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('aniGamerPlus+'),
          subtitle: Text('巴哈姆特動畫瘋下載器的手機端。片源與下載都在你自己的伺服器上。'),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 帳號卡

  Widget _card(BuildContext context) {
    final user = state.currentUser;
    final name = user?.username ?? '';
    final animes = state.animeHeads.length;
    final episodes = state.library.length;

    final String role;
    if (!state.serverInfo.userControl) {
      role = '未啟用用戶系統';
    } else if (user == null) {
      role = '尚未登入';
    } else {
      role = user.isAdmin ? '管理員' : '一般用戶';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(kRadius),
          border: Border.all(color: AgpColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: artFor(name.isEmpty ? 'aniGamerPlus' : name),
                shape: BoxShape.circle,
              ),
              child: Text(
                name.isEmpty ? '訪' : name.substring(0, 1).toUpperCase(),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isEmpty ? '訪客' : name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$role · 片庫 $animes 部 $episodes 集 · 收藏 ${state.favourites.length} 部',
                    style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('要登出嗎？'),
        content: const Text('登出後觀看紀錄不會再同步，已下載到手機的集數還在。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('登出'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await state.logout();
    if (context.mounted) toast(context, '已登出。');
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

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget Function() page,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => page()),
      ),
    );
  }
}
