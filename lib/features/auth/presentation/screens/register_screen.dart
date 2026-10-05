import 'package:flutter/material.dart';

import '../../data/signup_repository.dart';
import '../../domain/signup_request.dart';

/// 自助注册。提交后成为待审申请，管理员确认前不能登入使用。
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.repository});

  /// 测试用。正式页面不传。
  final SignupRepository? repository;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  late final SignupRepository _repository = widget.repository ?? SignupRepository();

  bool _consented = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    final problem = validateSignup(
      name: _name.text,
      email: _email.text,
      password: _password.text,
      consented: _consented,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }

    setState(() => _submitting = true);
    try {
      await _repository.submit(
        name: _name.text,
        email: _email.text,
        password: _password.text,
        phone: _phone.text,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('注册已提交'),
          content: const Text(
            '验证邮件已寄到你的邮箱。\n\n'
            '1. 打开邮件，点击验证链接。\n'
            '2. 等待管理员确认。确认后，就可以用这个邮箱和密码登入。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on SignupException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('注册')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '注册后需要管理员确认，确认前不能登入使用。',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '姓名'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _email,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    decoration: const InputDecoration(
                      labelText: '密码（至少 8 位）',
                    ),
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phone,
                    decoration: const InputDecoration(labelText: '电话（选填）'),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _consented,
                    onChanged: _submitting
                        ? null
                        : (value) => setState(() => _consented = value ?? false),
                    title: const Text(
                      '我同意教会使用我提供的姓名、电话、Email 和打卡记录，用于教会行政与出勤统计，可随时要求查看或删除。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: scheme.error)),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('提交注册'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
