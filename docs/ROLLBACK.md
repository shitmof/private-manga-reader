# 版本上传与回退

GitHub 私有仓库是源码与安装包的远端回退点；手机内漫画数据通过 `.mangabackup` 独立备份。两者不要混用。

## 开发升级：往上发送

```powershell
git status
git add --all
git commit -m "feat: describe the change"
git push origin main --follow-tags
```

发布稳定版本时创建注释标签：

```powershell
git tag -a v1.1.0 -m "Private Shelf v1.1.0"
git push origin v1.1.0
```

## 查看回退点

```powershell
git log --oneline --decorate --graph --all
git tag --list
```

当前约定：

- `backup-pre-mvp-20260829`：空白 Flutter 工程，功能实现前的最早回退点。
- `v1.0.0`：首个完整本地漫画阅读器版本。
- `backup-v1.0.0-pre-source-architecture-20260829`：引入书源与数据库迁移前的稳定点。
- `checkpoint-archive-import-20260829`：漫画压缩包顺序导入完成点。
- `checkpoint-network-mount-20260829`：网络挂载、只读缓存与设备验证完成点。
- `v1.1.0`：压缩包、回收站、网络书库和升级兼容的完整发布版。

## 安全回退：往下取版本

只查看旧版本，不改当前分支：

```powershell
git switch --detach v1.0.0
```

从旧版本建立修复分支：

```powershell
git switch -c codex/restore-v1.0.0 v1.0.0
```

不要使用 `git reset --hard` 覆盖未提交修改。先用 `git status` 检查，必要时提交或暂存当前工作。

Android 不允许把较低 `versionCode` 的 APK 直接覆盖到较高版本。需要在手机上回退功能时，必须基于目标旧源码构建一个使用相同签名、但 `versionCode` 高于手机当前版本的“前向回退 APK”；不要通过卸载 App 回退，因为卸载会清除私有数据。

## 手机数据回退

在 App 的“设置 → 备份与恢复”中创建 `.mangabackup`。恢复时 App 会先验证清单和每张原图哈希，并自动创建 `recovery-pre-restore-*.mangabackup`，之后才用备份结构替换当前书架。

私人漫画数据不会自动进入 GitHub。

升级 APK 不会移动或重编码 `assets/`。v1 数据库首次升级到 v3 前会自动保留 `library.db.pre-v3`；完整书架的数据回退仍以升级前导出的 `.mangabackup` 为准。
