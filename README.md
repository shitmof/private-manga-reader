# 私人书架

完全本地、私有、无社交负担的手机漫画与插画阅读器。

它只做一件事：把相册或文件中的原图复制进 App 私有目录，整理成一本本漫画，并以连续纵向方式安静阅读。

## 已实现

- 书架、漫画详情、三列编辑网格、沉浸式连续阅读和设置中心
- 从系统相册或文件选择器批量导入，保留选择顺序
- 导入原图不压缩、不重编码；复制后再次计算 SHA-256 校验
- 相同内容只物理保存一份，同一本或不同漫画可多次引用
- 单本最多 1000 张；支持拖动、正序、倒序、追加、删除引用和独立封面
- 逐项导入、失败项报告与原选择项直接重试
- 导入前估算体积，Android 实机检查私有目录所在磁盘的可用空间
- 永久原图与可清理、可重建的缩略图缓存分离
- 懒加载纵向阅读、横图完整显示、双击放大和阅读位置恢复
- 漫画自定义拖动排序、浅色/深色/跟随系统主题
- 完整 `.mangabackup` 备份与恢复；恢复前自动创建安全回退备份
- 无账号、无社交、无广告、无云同步，不把原图写回系统相册

空书架不会注入演示漫画或虚假图片。设计原稿只保存在 `docs/design-reference/`，不会打包为用户内容。

## 下载 Android 安装包

- [下载私人书架 v1.0.0 APK](https://github.com/shitmof/private-manga-reader/releases/download/v1.0.0/private-shelf-v1.0.0-android.apk)
- 文件大小：56,044,267 字节（约 53.4 MiB）
- SHA-256：`2AC9310AAF313FEBC7B0E03447F7F97025107E68ACAA74E26E0FA3AE5D01293C`

仓库是私有仓库，下载时需要登录获授权的 GitHub 账号。

## 数据结构

```text
App Documents/private_shelf/
├── assets/          # 以内容哈希命名的原始文件
├── thumbnails/      # 可清理、可重建的缩略图
├── backup-temp/     # 导入、备份和恢复临时文件
└── backups/         # App 内最近创建的完整备份

Application Support/
└── library.db       # 漫画、引用顺序、封面、进度和设置
```

SQLite 只保存相对路径。备份恢复到另一台设备时不会依赖旧设备绝对路径。

## 开发与验证

本机 Flutter SDK：`E:\CodexStorage\toolchains\flutter`。

```powershell
$flutterExe = 'E:\CodexStorage\toolchains\flutter\bin\flutter.bat'
& $flutterExe pub get
& $flutterExe analyze
& $flutterExe test
& $flutterExe build apk --release
```

Windows 上 Flutter 分析服务对中文工程路径存在已知兼容问题。本项目保留在统一中文目录中，开发时可从英文 Junction 进入；Android 构建已在项目级关闭 Kotlin 增量缓存，避免 Pub 缓存位于 C 盘而工程位于 E 盘时的跨盘路径问题。

## 产品与回退

- 产品行为规格：[docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md)
- 版本回退说明：[docs/ROLLBACK.md](docs/ROLLBACK.md)
- 验收证据：[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)

Git 仓库保存源码和设计参考，完整安装包作为 GitHub Release 附件发布；两者都不会保存用户在 App 中导入的私人漫画原图。
