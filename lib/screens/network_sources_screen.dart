import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import 'network_library_screen.dart';

class NetworkSourcesScreen extends StatelessWidget {
  const NetworkSourcesScreen({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('网络书库'),
          actions: <Widget>[
            IconButton(
              tooltip: '添加网络书库',
              onPressed: () => _addSource(context),
              icon: const Icon(Icons.add_rounded),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: controller.networkSources.isEmpty
            ? _EmptyNetworkLibrary(onAdd: () => _addSource(context))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                itemCount: controller.networkSources.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final source = controller.networkSources[index];
                  final books = controller.booksForSource(source.id);
                  return Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: ShelfColors.blueSoft,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          _sourceIcon(source.type),
                          color: ShelfColors.blue,
                        ),
                      ),
                      title: Text(source.name),
                      subtitle: Text(
                        '${_typeLabel(source.type)} · ${books.length} 本\n${source.endpoint}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => NetworkLibraryScreen(
                            controller: controller,
                            sourceId: source.id,
                          ),
                        ),
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'refresh') _refresh(context, source);
                          if (value == 'credentials') {
                            _reauthenticate(context, source);
                          }
                          if (value == 'delete') _remove(context, source);
                        },
                        itemBuilder: (context) =>
                            const <PopupMenuEntry<String>>[
                              PopupMenuItem(
                                value: 'refresh',
                                child: Text('重新扫描'),
                              ),
                              PopupMenuItem(
                                value: 'credentials',
                                child: Text('更新账号密码'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('移除挂载'),
                              ),
                            ],
                      ),
                    ),
                  );
                },
              ),
        floatingActionButton: controller.networkSources.isEmpty
            ? null
            : FloatingActionButton(
                tooltip: '添加网络书库',
                onPressed: () => _addSource(context),
                child: const Icon(Icons.add_rounded),
              ),
      ),
    );
  }

  Future<void> _addSource(BuildContext context) async {
    final source = await Navigator.of(context).push<NetworkSource>(
      MaterialPageRoute<NetworkSource>(
        builder: (_) => _NetworkSourceForm(controller: controller),
      ),
    );
    if (source != null && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              NetworkLibraryScreen(controller: controller, sourceId: source.id),
        ),
      );
    }
  }

  Future<void> _refresh(BuildContext context, NetworkSource source) async {
    try {
      await controller.scanNetworkSource(source);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已同步 ${source.name}')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('同步失败：${_friendly(error)}')));
      }
    }
  }

  Future<void> _remove(BuildContext context, NetworkSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除网络书库？'),
        content: Text('将移除“${source.name}”的挂载与本地缓存。远程文件不会被修改或删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除挂载'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.removeNetworkSource(source.id);
  }

  Future<void> _reauthenticate(
    BuildContext context,
    NetworkSource source,
  ) async {
    final username = TextEditingController(text: source.username);
    final password = TextEditingController();
    final domain = TextEditingController();
    final credentials = await showDialog<NetworkCredentials>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更新账号密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: username,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            if (source.type == NetworkSourceType.smb) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: domain,
                decoration: const InputDecoration(labelText: '域（可选）'),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              NetworkCredentials(
                username: username.text.trim(),
                password: password.text,
                domain: domain.text.trim(),
              ),
            ),
            child: const Text('验证并保存'),
          ),
        ],
      ),
    );
    username.dispose();
    password.dispose();
    domain.dispose();
    if (credentials == null) return;
    try {
      await controller.reauthenticateNetworkSource(source, credentials);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('账号密码已更新')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('验证失败：${_friendly(error)}')));
      }
    }
  }
}

class _NetworkSourceForm extends StatefulWidget {
  const _NetworkSourceForm({required this.controller});

  final AppController controller;

  @override
  State<_NetworkSourceForm> createState() => _NetworkSourceFormState();
}

class _NetworkSourceFormState extends State<_NetworkSourceForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _root = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _domain = TextEditingController();
  NetworkSourceType _type = NetworkSourceType.webdav;
  bool _obscurePassword = true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _root.dispose();
    _username.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加网络书库')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: <Widget>[
            Text('连接类型', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 9),
            SegmentedButton<NetworkSourceType>(
              segments: const <ButtonSegment<NetworkSourceType>>[
                ButtonSegment(
                  value: NetworkSourceType.webdav,
                  label: Text('WebDAV'),
                ),
                ButtonSegment(
                  value: NetworkSourceType.opds,
                  label: Text('OPDS'),
                ),
                ButtonSegment(value: NetworkSourceType.smb, label: Text('SMB')),
              ],
              selected: <NetworkSourceType>{_type},
              onSelectionChanged: _saving
                  ? null
                  : (value) => setState(() => _type = value.first),
            ),
            const SizedBox(height: 22),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              textInputAction: TextInputAction.next,
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入书库名称' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _endpoint,
              decoration: InputDecoration(
                labelText: _type == NetworkSourceType.smb ? 'SMB 主机' : '服务地址',
                hintText: switch (_type) {
                  NetworkSourceType.webdav => 'https://example.com/dav',
                  NetworkSourceType.opds => 'https://example.com/opds',
                  NetworkSourceType.smb => 'smb://192.168.1.10',
                },
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.trim().isEmpty) return '请输入服务地址';
                final uri = Uri.tryParse(value.trim());
                if (_type != NetworkSourceType.smb &&
                    (uri == null ||
                        !uri.hasScheme ||
                        (uri.scheme != 'http' && uri.scheme != 'https'))) {
                  return '请输入完整的 http:// 或 https:// 地址';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _root,
              decoration: InputDecoration(
                labelText: _type == NetworkSourceType.smb ? '共享与目录' : '根目录（可选）',
                hintText: _type == NetworkSourceType.smb
                    ? '/share/manga'
                    : '/manga',
              ),
              validator: (value) =>
                  _type == NetworkSourceType.smb &&
                      (value == null || value.trim().isEmpty)
                  ? '请输入 SMB 共享名和目录'
                  : null,
            ),
            const SizedBox(height: 22),
            Text('认证', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 9),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: '用户名（可选）'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '密码（可选）',
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            if (_type == NetworkSourceType.smb) ...<Widget>[
              const SizedBox(height: 14),
              TextFormField(
                controller: _domain,
                decoration: const InputDecoration(labelText: '域（可选）'),
              ),
            ],
            const SizedBox(height: 14),
            const Text(
              '密码使用系统安全存储加密，不写入数据库或完整备份。远程连接始终只读。',
              style: TextStyle(color: ShelfColors.muted, height: 1.45),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '正在验证连接…' : '验证并挂载'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = await widget.controller.addNetworkSource(
        name: _name.text.trim(),
        type: _type,
        endpoint: _endpoint.text.trim(),
        rootPath: _root.text.trim(),
        credentials: NetworkCredentials(
          username: _username.text.trim(),
          password: _password.text,
          domain: _domain.text.trim(),
        ),
      );
      if (mounted) Navigator.pop(context, source);
    } catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('无法连接'),
            content: Text(_friendly(error)),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _EmptyNetworkLibrary extends StatelessWidget {
  const _EmptyNetworkLibrary({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: ShelfColors.blueSoft,
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.cloud_outlined,
                size: 42,
                color: ShelfColors.blue,
              ),
            ),
            const SizedBox(height: 24),
            Text('挂载你的网络书库', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            const Text(
              '支持 WebDAV、OPDS/Komga/Kavita 和 SMB/NAS。远程文件只读，阅读记录只留在本机。',
              textAlign: TextAlign.center,
              style: TextStyle(color: ShelfColors.muted, height: 1.55),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('添加网络书库'),
            ),
          ],
        ),
      ),
    );
  }
}

String _typeLabel(NetworkSourceType type) => switch (type) {
  NetworkSourceType.webdav => 'WebDAV',
  NetworkSourceType.opds => 'OPDS',
  NetworkSourceType.smb => 'SMB/NAS',
};

IconData _sourceIcon(NetworkSourceType type) => switch (type) {
  NetworkSourceType.webdav => Icons.cloud_outlined,
  NetworkSourceType.opds => Icons.rss_feed_rounded,
  NetworkSourceType.smb => Icons.dns_outlined,
};

String _friendly(Object error) => error
    .toString()
    .replaceFirst('FormatException: ', '')
    .replaceFirst('Bad state: ', '');
