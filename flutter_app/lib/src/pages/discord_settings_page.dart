import 'dart:io';

import 'package:flutter/material.dart';
import '../api/client.dart';

import '../state/app_state.dart';
import '../util/device.dart';
import '../widgets/common.dart';
import '../widgets/tv_settings_list.dart';
import 'discord_login_page.dart';

class DiscordSettingsPage extends StatefulWidget {
  const DiscordSettingsPage({super.key, required this.state});
  final AppState state;
  @override
  State<DiscordSettingsPage> createState() => _DiscordSettingsPageState();
}

class _DiscordSettingsPageState extends State<DiscordSettingsPage> {
  AppState get state => widget.state;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        toast(context,
            error is ApiException ? error.message : '操作失敗，請確認登入資料與連線後再試。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _password(String title) async {
    final text = TextEditingController();
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(title),
              content: TextField(
                  controller: text,
                  obscureText: true,
                  autofocus: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration:
                      const InputDecoration(labelText: 'aniGamerPlus 伺服器密碼'),
                  onSubmitted: (value) {
                    if (value.isNotEmpty) Navigator.pop(context, value);
                  }),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () {
                      if (text.text.isNotEmpty) {
                        Navigator.pop(context, text.text);
                      }
                    },
                    child: const Text('確認'))
              ],
            ));
    // Keep the controller alive until the dialog's exit transition finishes.
    Future<void>.delayed(const Duration(milliseconds: 300), text.dispose);
    return value;
  }

  Future<void> _sync() async {
    final password = await _password('加密同步 Discord 登入');
    if (password == null || !mounted) return;
    await state.discord.sync(state.client, password);
    if (mounted) toast(context, 'Discord 登入已加密同步到伺服器');
  }

  Future<void> _login() async {
    final linked = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => DiscordLoginPage(presence: state.discord)));
    if (linked != true || !mounted) return;
    await state.discord.setEnabled(true);
    if (state.loggedIn) await _sync();
  }

  Widget _tile(String title, String subtitle, VoidCallback action,
          {bool autofocus = false}) =>
      TvSettingsTile(
          label: title,
          autofocus: autofocus,
          onActivate: () {
            if (!_busy) action();
          },
          child: ListTile(
              title: Text(title),
              subtitle: Text(subtitle),
              enabled: !_busy,
              onTap: action,
              trailing: const Icon(Icons.chevron_right_rounded)));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Discord 播放動態')),
        body: ListenableBuilder(
          listenable: Listenable.merge([state.discord, state.tvRemote]),
          builder: (context, _) => TvSettingsList(
              child: ListView(children: [
            if (_busy) const LinearProgressIndicator(),
            ListTile(
                title: Text(state.discord.name.isEmpty
                    ? 'Discord'
                    : state.discord.name),
                subtitle: Text(state.discord.status)),
            TvSettingsTile(
                label: '顯示播放動態',
                autofocus: true,
                onActivate: () => _run(
                    () => state.discord.setEnabled(!state.discord.enabled)),
                child: SwitchListTile(
                    title: const Text('顯示播放動態'),
                    subtitle: const Text('顯示作品、集數、播放進度與暫停狀態'),
                    value: state.discord.enabled,
                    onChanged: _busy
                        ? null
                        : (value) =>
                            _run(() => state.discord.setEnabled(value)))),
            if (!Device.tv && (Platform.isAndroid || Platform.isIOS))
              _tile('登入 Discord', '使用 Discord 登入頁連結你的帳號', () => _run(_login)),
            if (Device.tv)
              const ListTile(
                  title: Text('使用手機登入'),
                  subtitle: Text('在手機登入 Discord，連上這台電視的遙控器後，選擇「傳送到電視」。')),
            if (state.loggedIn) ...[
              if (state.discord.linked)
                _tile('加密同步到伺服器', '使用伺服器密碼保護登入資料', () => _run(_sync)),
              _tile(
                  '從伺服器解鎖',
                  '輸入伺服器密碼，在這台裝置還原 Discord 登入',
                  () => _run(() async {
                        final password = await _password('解鎖 Discord 登入');
                        if (password == null || !mounted) return;
                        final found =
                            await state.discord.unlock(state.client, password);
                        if (found) await state.discord.setEnabled(true);
                        if (mounted) {
                          toast(context,
                              found ? 'Discord 已解鎖' : '伺服器尚未保存 Discord 登入');
                        }
                      })),
              _tile(
                  '刪除伺服器上的 Discord 登入',
                  '同時登出這台裝置；其他裝置可各自登出',
                  () => _run(() async {
                        await state.discord
                            .forget(client: state.client, remote: true);
                        if (mounted) toast(context, '已刪除同步資料');
                      })),
            ] else
              const ListTile(
                  title: Text('跨裝置同步'),
                  subtitle:
                      Text('登入 aniGamerPlus 伺服器帳號後，可使用密碼加密同步 Discord 登入。')),
            if (!Device.tv && state.discord.linked && state.tvRemote.connected)
              _tile(
                  '傳送到電視',
                  '傳送到「${state.tvRemote.device?.name ?? '電視'}」並啟用播放動態',
                  () => _run(() async {
                        await state.discord.shareWithTv(state.tvRemote);
                        if (mounted) toast(context, 'Discord 已傳送到電視');
                      })),
            if (state.discord.linked)
              _tile('登出這台裝置的 Discord', '停止顯示動態，刪除這台裝置的登入',
                  () => _run(() => state.discord.forget())),
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text('修改或重設伺服器密碼後，需重新加密同步 Discord 登入。')),
          ])),
        ),
      );
}
