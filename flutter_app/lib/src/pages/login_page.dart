/// 登入 —— 對應 templates/login.html.
///
/// 網頁版是 form POST 之後靠 302 帶回 Set-Cookie; 這裡由 AgpClient 自己攔
/// 重導向把 token 撿出來, 畫面只負責收兩個欄位.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.state});

  final AppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();
  bool _busy = false;
  bool _obscure = true;
  String _error = '';

  AppState get state => widget.state;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '請把帳號跟密碼都填好。');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await state.login(username, password);
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
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
    toast(context, '歡迎回來，$username。');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登入')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Text(
            state.client.baseUrl,
            style: const TextStyle(fontSize: 12.5, color: AgpColors.fgFaint),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '帳號',
              prefixIcon: Icon(Icons.person_outline),
            ),
            onSubmitted: (_) => _passwordFocus.requestFocus(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            focusNode: _passwordFocus,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '密碼',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
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
                : const Text('登入'),
          ),
          if (state.serverInfo.allowRegister) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => RegisterPage(state: state),
                      )),
              child: const Text('註冊新帳號'),
            ),
          ],
          const SizedBox(height: 18),
          const Text(
            '觀看紀錄存在伺服器上，換裝置登入同一個帳號就找得回來。已經下載到這支手機的集數不受影響。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: AgpColors.fgFaint),
          ),
        ],
      ),
    );
  }
}
