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

## 手机数据回退

在 App 的“设置 → 备份与恢复”中创建 `.mangabackup`。恢复时 App 会先验证清单和每张原图哈希，并自动创建 `recovery-pre-restore-*.mangabackup`，之后才用备份结构替换当前书架。

私人漫画数据不会自动进入 GitHub。
