import 'package:flutter/material.dart';

import '../models/entities.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import 'network_library_screen.dart';

enum _SourceChoice { local, network }

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
              tooltip: '添加书库',
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
                        child: Stack(
                          children: <Widget>[
                            Center(
                              child: Icon(
                                _sourceIcon(source.type),
                                color: ShelfColors.blue,
                              ),
                            ),
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _statusColor(source.connectionState),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surface,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      title: Text(source.name),
                      subtitle: Text(
                        '${_typeLabel(source.type)} · ${books.length} 本 · ${_statusLabel(source)}\n'
                        '${source.type == NetworkSourceType.local ? source.rootPath : source.endpoint}'
                        '${source.lastError == null ? '' : '\n${source.lastError}'}',
                        maxLines: 3,
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
                          if (value == 'relink') _relink(context, source);
                          if (value == 'delete') _remove(context, source);
                        },
                        itemBuilder: (context) => <PopupMenuEntry<String>>[
                          const PopupMenuItem(
                            value: 'refresh',
                            child: Text('重新扫描'),
                          ),
                          if (source.type != NetworkSourceType.local)
                            const PopupMenuItem(
                              value: 'credentials',
                              child: Text('更新账号密码'),
                            ),
                          if (source.type == NetworkSourceType.local)
                            const PopupMenuItem(
                              value: 'relink',
                              child: Text('重新选择原目录'),
                            ),
                          const PopupMenuItem(
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
                tooltip: '添加书库',
                onPressed: () => _addSource(context),
                child: const Icon(Icons.add_rounded),
              ),
      ),
    );
  }

  Future<void> _addSource(BuildContext context) async {
    final choice = await showModalBottomSheet<_SourceChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ListTile(
              leading: Icon(Icons.folder_open_rounded),
              title: Text('挂载本地漫画目录'),
              subtitle: Text('ZIP/CBZ 与图片文件夹原地直读，不复制原图'),
              onTap: null,
            ),
            ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('选择手机、SD 卡或系统目录'),
              onTap: () => Navigator.pop(context, _SourceChoice.local),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('连接网络书库'),
              subtitle: const Text('WebDAV、OPDS 或 SMB/NAS'),
              onTap: () => Navigator.pop(context, _SourceChoice.network),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == _SourceChoice.local) {
      try {
        final source = await controller.mountLocalDirectory();
        if (source != null && context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NetworkLibraryScreen(
                controller: controller,
                sourceId: source.id,
              ),
            ),
          );
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('挂载失败：${_friendly(error)}')));
        }
      }
      return;
    }
    await _addNetworkSource(context);
  }

  Future<void> _addNetworkSource(BuildContext context) async {
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
        content: Text(
          source.type == NetworkSourceType.local
              ? '将移除“${source.name}”的授权与索引。原图和压缩包不会被修改或删除。'
              : '将移除“${source.name}”的挂载与本地缓存。远程文件不会被修改或删除。',
        ),
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

  Future<void> _relink(BuildContext context, NetworkSource source) async {
    try {
      await controller.relinkLocalSource(source);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已重新关联原目录')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重新关联失败：${_friendly(error)}')));
      }
    }
  }

  Future<void> _reauthenticate(
    BuildContext context,
    NetworkSource source,
  ) async {
    var username = source.username;
    var password = '';
    var domain = '';
    final credentials = await showDialog<NetworkCredentials>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更新账号密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              initialValue: username,
              onChanged: (value) => username = value,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: (value) => password = value,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
            if (source.type == NetworkSourceType.smb) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                onChanged: (value) => domain = value,
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
                username: username.trim(),
                password: password,
                domain: domain.trim(),
              ),
            ),
            child: const Text('验证并保存'),
          ),
        ],
      ),
    );
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
                  NetworkSourceType.local => '',
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
            Text('挂载你的漫画书库', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            const Text(
              '可原地挂载手机或 SD 卡的 ZIP/CBZ 与图片目录，也支持 WebDAV、OPDS 和 SMB/NAS。所有阅读记录都只留在本机。',
              textAlign: TextAlign.center,
              style: TextStyle(color: ShelfColors.muted, height: 1.55),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加书库'),
            ),
          ],
        ),
      ),
    );
  }
}

String _typeLabel(NetworkSourceType type) => switch (type) {
  NetworkSourceType.local => '本地原地挂载',
  NetworkSourceType.webdav => 'WebDAV',
  NetworkSourceType.opds => 'OPDS',
  NetworkSourceType.smb => 'SMB/NAS',
};

IconData _sourceIcon(NetworkSourceType type) => switch (type) {
  NetworkSourceType.local => Icons.folder_open_rounded,
  NetworkSourceType.webdav => Icons.cloud_outlined,
  NetworkSourceType.opds => Icons.rss_feed_rounded,
  NetworkSourceType.smb => Icons.dns_outlined,
};

String _friendly(Object error) => error
    .toString()
    .replaceFirst('FormatException: ', '')
    .replaceFirst('Bad state: ', '');

String _statusLabel(NetworkSource source) {
  final state = switch (source.connectionState) {
    NetworkConnectionState.unknown => '待检查',
    NetworkConnectionState.connected => '已连接',
    NetworkConnectionState.needsAuthentication => '需重新登录',
    NetworkConnectionState.offline => '网络离线',
    NetworkConnectionState.unreachable => '暂时不可达',
  };
  final last = source.lastSuccessAt;
  if (last == null) return state;
  final local = last.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '$state · ${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

Color _statusColor(NetworkConnectionState state) => switch (state) {
  NetworkConnectionState.connected => const Color(0xFF22A06B),
  NetworkConnectionState.needsAuthentication => const Color(0xFFE08022),
  NetworkConnectionState.offline ||
  NetworkConnectionState.unreachable => const Color(0xFFD94C4C),
  NetworkConnectionState.unknown => ShelfColors.muted,
};
