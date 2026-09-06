/// 帳號資訊 —— 對應 templates/userinfo.html, 目前就只有改密碼一件事.
///
/// 伺服器改完密碼會重新產一組 token, 手上這一組立刻失效, 所以改完必須
/// 直接登出重登 —— 網頁版靠回應裡的 logout:true 做同一件事.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../util/format.dart';
import '../widgets/common.dart';
import 'login_page.dart';

class UserInfoPage extends StatefulWidget {
  const UserInfoPage({super.key, required this.state});

  final AppState state;

  @override
  State<UserInfoPage> createState() => _UserInfoPageState();
}

class _UserInfoPageState extends State<UserInfoPage> {
  final TextEditingController _old = TextEditingController();
  final TextEditingController _new1 = TextEditingController();
  final TextEditingController _new2 = TextEditingController();
  bool _busy = false;
  String _error = '';

  AppState get state => widget.state;

  @override
  void dispose() {
    _old.dispose();
    _new1.dispose();
    _new2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_old.text.isEmpty || _new1.text.isEmpty || _new2.text.isEmpty) {
      setState(() => _error = '請把三個欄位都填滿。');
      return;
    }
    if (_new1.text != _new2.text) {
      setState(() => _error = '新密碼不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });

    String message;
    try {
      message = await state.client.changePassword(_old.text, _new1.text, _new2.text);
    } on ApiException catch (error) {
      setState(() {
        _busy = false;
        _error = error.message;
      });
      return;
    } catch (error) {
      setState(() {
        _busy = false;
        _error = '連不上伺服器: $error';
      });
      return;
    }

    // token 已經被伺服器換掉了, 留著只會一直被當成沒登入
    await state.logout();
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginPage(state: state)),
    );
    toast(context, '$message 請重新登入。');
  }

  @override
  Widget build(BuildContext context) {
    final user = state.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('帳號資訊')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: artFor(user?.username ?? 'aniGamerPlus'),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  (user?.username ?? '?').isEmpty
                      ? '?'
                      : user!.username.substring(0, 1).toUpperCase(),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.username ?? '未登入',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user == null
                        ? ''
                        : (user.isAdmin ? '管理員 · 可以下載新的集數' : '一般用戶 · 只能觀看'),
                    style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 26),
          const Text(
            '修改密碼',
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _old,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '目前的密碼',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _new1,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '新密碼',
              helperText: '6-64 個英數字或底線',
              prefixIcon: Icon(Icons.lock_reset_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _new2,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '再輸入一次新密碼',
              prefixIcon: Icon(Icons.lock_reset_outlined),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error,
                style: const TextStyle(fontSize: 13, color: AgpColors.accent),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('修改密碼'),
          ),
          const SizedBox(height: 14),
          const Text(
            '改完密碼後這支手機會自動登出，用新密碼重新登入即可。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: AgpColors.fgFaint),
          ),
        ],
      ),
    );
  }
}
