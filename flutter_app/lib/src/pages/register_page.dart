/// 註冊 —— 對應 templates/register.html.
///
/// 帳號 3-20 個英數字或底線、密碼 6-64, 這是伺服器那邊的正規表示式,
/// 先在這裡擋一次, 使用者不用等一趟往返才知道打錯.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key, required this.state});

  final AppState state;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _pw1 = TextEditingController();
  final TextEditingController _pw2 = TextEditingController();
  bool _busy = false;
  String _error = '';

  static final RegExp _usernameRule = RegExp(r'^[a-zA-Z0-9_]{3,20}$');
  static final RegExp _passwordRule = RegExp(r'^[a-zA-Z0-9_]{6,64}$');

  @override
  void dispose() {
    _username.dispose();
    _pw1.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final pw1 = _pw1.text;
    final pw2 = _pw2.text;

    String? complaint;
    if (username.isEmpty || pw1.isEmpty || pw2.isEmpty) {
      complaint = '請把欄位都填滿';
    } else if (!_usernameRule.hasMatch(username)) {
      complaint = '帳號只能用 3-20 個英數字或底線';
    } else if (pw1 != pw2) {
      complaint = '兩次輸入的密碼不一致';
    } else if (!_passwordRule.hasMatch(pw1)) {
      complaint = '密碼只能用 6-64 個英數字或底線';
    }
    if (complaint != null) {
      setState(() => _error = complaint!);
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.state.client.register(username, pw1, pw2);
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
    toast(context, '註冊成功，用新帳號登入吧。');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('註冊')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          TextField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '帳號',
              helperText: '3-20 個英數字或底線',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _pw1,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '密碼',
              helperText: '6-64 個英數字或底線',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _pw2,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '再輸入一次密碼',
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
                : const Text('建立帳號'),
          ),
          const SizedBox(height: 16),
          const Text(
            '新帳號預設是一般用戶，只能看片與同步進度。要下載新的集數得請站台管理員把角色改成 admin。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: AgpColors.fgFaint),
          ),
        ],
      ),
    );
  }
}
