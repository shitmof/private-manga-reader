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
git tag -a v1.4.0 -m "Shihuage v1.4.0"
git push origin v1.4.0
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
- `backup-pre-editor-fix-20260830`：编辑页“选中删除保存”回归修复前的 v1.1.0 稳定点。
- `backup-pre-v1.2-20260830`：v1.2 文件夹、快速定位、私密和备份强化实现前的回退点。
- `v1.2.0`：三列分组书架、完整编辑、快速定位、私密阅读、CBZ 导出、文件关联和可卸载恢复备份的正式版。
- `backup-pre-v1.3-20260830`：拾画阁改名、混合书架和 SAF 原地挂载实施前的 v1.2 稳定点。
- `checkpoint-v1.3-brand-navigation`：拾画阁品牌、图标、统一返回和设置页收敛完成点。
- `checkpoint-v1.3-shelf-groups-reorder`：固定四宫格分组与主书架混合拖动排序完成点。
- `checkpoint-v1.3-local-mount-storage`：Android SAF 图片目录和 ZIP/CBZ 原地直读完成点。
- `v1.3.0`：拾画阁品牌、混合书架排序、四宫格分组和低占用本地原地挂载正式版。
- `backup-pre-v1.4-20260830`：主书架直接拖动合组与阅读器交互纠偏实施前的回退点。
- `checkpoint-v1.4-shelf-reader`：书碰书原子合组、主书架拖动和阅读器按需纵向定位完成点。
- `checkpoint-v1.4-final-code`：书单内部排序与拖回主书架闭环完成点。
- `v1.4.0`：主书架直接拖动、跨屏边缘滚动、确认合组、书单内外移动与无横线阅读器正式版。

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

Android 不允许把较低 `versionCode` 的 APK 直接覆盖到较高版本。需要在手机上回退功能时，必须基于目标旧源码构建一个使用相同签名、但 `versionCode` 高于当前版本的“前向回退 APK”；不要通过卸载 App 回退，因为卸载会清除私有数据。

## 手机数据回退

在 App 的“设置 → 备份与恢复”中创建 `.mangabackup`。恢复时 App 会先验证清单和每张原图哈希，并自动创建 `recovery-pre-restore-*.mangabackup`，之后才用备份结构替换当前书架。

私人漫画数据不会自动进入 GitHub。

升级 APK 不会移动或重编码 `assets/`。数据库首次升级到 schema 6、7 前分别会自动保留 `library.db.pre-v6`、`library.db.pre-v7`；完整书架的数据回退仍以升级前导出的 `.mangabackup` 为准。SAF 挂载的原文件始终位于用户选择的外部目录，恢复备份后需要重新选择该目录恢复授权。
