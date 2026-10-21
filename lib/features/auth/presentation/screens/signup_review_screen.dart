import 'package:flutter/material.dart';

import '../../data/signup_repository.dart';
import '../../domain/signup_request.dart';

/// 管理员审核自助注册的申请。通过的人成为组员（没有群组和牧区），之后再由管理员分配。
class SignupReviewScreen extends StatefulWidget {
  const SignupReviewScreen({super.key, this.repository});

  /// 测试用。正式页面不传。
  final SignupRepository? repository;

  @override
  State<SignupReviewScreen> createState() => _SignupReviewScreenState();
}

class _SignupReviewScreenState extends State<SignupReviewScreen> {
  late final SignupRepository _repository =
      widget.repository ?? SignupRepository();
  late Future<List<SignupRequest>> _future = _repository.pendingRequests();
  String? _message;

  void _reload() {
    setState(() => _future = _repository.pendingRequests());
  }

  Future<void> _approve(SignupRequest request) async {
    final ok = await _confirm(
      title: '通过注册',
      text: '${request.name} 将成为组员，没有服事编辑权限，也没有牧区。之后可以在「帐号管理」里再设定。',
      action: '通过',
    );
    if (!ok) return;
    try {
      await _repository.approve(request);
      if (!mounted) return;
      setState(() => _message = '已通过：${request.name}');
      _reload();
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = '通过失败，请稍后再试');
    }
  }

  Future<void> _reject(SignupRequest request) async {
    final ok = await _confirm(
      title: '拒绝注册',
      text: '拒绝后会删除 ${request.name} 的申请。',
      action: '拒绝',
    );
    if (!ok) return;
    try {
      await _repository.reject(request.uid);
      if (!mounted) return;
      setState(() => _message = '已拒绝：${request.name}');
      _reload();
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = '操作失败，请稍后再试');
    }
  }

  Future<bool> _confirm({
    required String title,
    required String text,
    required String action,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('待审核的注册')),
      body: FutureBuilder<List<SignupRequest>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('无法读取申请，请稍后再试'));
          }
          final requests = snapshot.data ?? const <SignupRequest>[];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_message!),
                ),
              if (requests.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('目前没有待审的注册')),
                ),
              for (final request in requests)
                Card(
                  child: ListTile(
                    title: Text(request.name),
                    subtitle: Text(
                      request.phone.isEmpty
                          ? request.email
                          : '${request.email} · ${request.phone}',
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () => _reject(request),
                          child: const Text('拒绝'),
                        ),
                        FilledButton(
                          onPressed: () => _approve(request),
                          child: const Text('通过'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
