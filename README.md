# 拾画阁

本地优先、私有、无社交负担的手机漫画与插画阅读器。

它可以把相册、文件或漫画压缩包中的原图整理成一本本漫画，也可以原地挂载手机目录或只读挂载个人网络书库；阅读记录始终保存在本机。

## 已实现

- 书架、漫画详情、三列编辑网格、沉浸式连续阅读和设置中心
- 三列书架、文件夹分组、拖入分组、置顶、书单、搜索与私密书架
- 主书架中的漫画和四宫格分组可混合拖动排序，分组始终显示固定 2×2 封面框
- 从系统相册或文件选择器批量导入，保留选择顺序
- 整包导入 CBZ/ZIP、CBR/RAR、CB7/7z、CBT/TAR；读取 `ComicInfo.xml`，按作者目录与数字自然顺序建册
- 多个压缩包按系统选择队列依次解压；后一包始终追加在前一包末尾
- App 不设单批 100 张限制；可连续追加，单本统一上限为 1000 张
- 导入原图不压缩、不重编码；复制后再次计算 SHA-256 校验
- 相同内容只物理保存一份，同一本或不同漫画可多次引用
- 单本最多 1000 张；支持单选、多选、全选、范围选择、批量删除、块移动、页码移动与独立封面
- 逐项导入、失败项报告与原选择项直接重试
- 导入前估算体积，Android 实机检查私有目录所在磁盘的可用空间
- 永久原图与可清理、可重建的缩略图缓存分离
- 懒加载纵向阅读、横图完整显示、双击放大、阅读亮度、页面书签和阅读位置恢复
- 阅读器右侧设 48dp 热区、可开关的纵向定位条：仅触碰或拖动时显示，松手约 1.1 秒后完全隐藏；600～1000 页也可直接跳转
- 阅读控制层只显示紧凑页码胶囊，不再显示横跨底部的进度 Slider；新安装默认图片间距为 0dp
- 漫画自定义拖动排序、浅色/深色/跟随系统主题
- 完整 `.mangabackup` 备份与恢复；可通过系统文档选择器保存到手机、SD 卡或云盘，卸载后仍可找回
- 漫画移入回收站、恢复、永久删除；页面多选删除与无引用原图清理彼此分离
- 只读挂载 WebDAV、OPDS/Komga/Kavita、SMB/NAS；网络缓存可清，阅读进度留在本机
- Android SAF 原地挂载图片目录和 ZIP/CBZ：不复制原文件，压缩包按需直读，仅保存可重建索引和受控图片缓存
- 挂载记录连接状态、最后成功/同步时间、脱敏错误和重新认证入口
- Android 文件关联：在文件管理器点击 CBZ/ZIP/CBR/RAR/CB7/7z/CBT/TAR 可直接进入导入流程
- 本地漫画按当前编辑顺序无损导出 CBZ，并可保存到手机/云盘或调用系统分享
- 网络密码使用 Android 安全存储，不进入 SQLite、完整备份或 GitHub
- 无痕模式：一键禁止全应用截屏与录屏（`FLAG_SECURE` 引用计数），并在切到后台时遮盖界面；阅读章节自动叠加私密保护
- 阅读亮度可跟随手机自身亮度，也可继续使用应用内固定亮度
- 无 App 账号、无社交、无广告、无云同步，不把原图写回系统相册

空书架不会注入演示漫画或虚假图片。设计原稿只保存在 `docs/design-reference/`，不会打包为用户内容。

## 下载 Android 安装包

- [下载拾画阁 v1.6.2 APK](https://github.com/shitmof/private-manga-reader/releases/download/v1.6.2/shihuage-v1.6.2-android.apk)
- 文件大小与 SHA-256：见对应 Release 说明
- 兼容 ABI：`arm64-v8a`、`armeabi-v7a`、`x86_64`
- **签名证书 SHA-256**：`1F6A95C4786F85D1F39DEDDBF61D0BCC56BEB2D9A59F1A3CA43AAF70B8A8391A`
- 这是**唯一渠道**：v1.6.0 / v1.6.1 / v1.6.2 使用同一把密钥，已装 v1.6.0 或 v1.6.1 可直接覆盖升级、保留数据，无需卸载。

## 构建时的签名

本仓库只使用**一把**签名密钥。`android/key.properties`（**不进版本库**）显式指定它，
避免 Gradle 因 `ANDROID_USER_HOME` / `ANDROID_SDK_HOME` 指向不同目录而悄悄换用另一把
debug 密钥——那会签出「同一台设备无法覆盖安装」的包。

```properties
storeFile=shihuage-v160-channel.keystore
storePassword=android
keyAlias=androiddebugkey
keyPassword=android
expectedCertSha256=1F6A95C4786F85D1F39DEDDBF61D0BCC56BEB2D9A59F1A3CA43AAF70B8A8391A
```

- `key.properties` 缺失、未声明 `storeFile`、或 `expectedCertSha256` 与实际指纹不符时，
  构建**直接失败**，不会静默回退到默认密钥。
- 只有显式传 `-PallowDebugSigning=true`（本地开发）才跳过校验。
- 构建日志会打印实际使用的密钥路径与证书指纹。
- 解析时会剥离 UTF-8 BOM（Windows 的 `Set-Content -Encoding UTF8` 会写入 BOM，
  BOM 会污染第一行键名使 `storeFile` 失效）。
- 未提供 `key.properties` 时回退到 `$HOME/.android/debug.keystore`，构建日志会打印实际使用的路径。

仓库与 Release 已公开，无需登录即可下载。仓库当前未附加开源许可证，默认保留所有权利；公开不代表自动授权复制、修改或再分发。

## 数据结构

```text
App Documents/private_shelf/
├── assets/          # 以内容哈希命名的原始文件
├── thumbnails/      # 可清理、可重建的缩略图
├── backup-temp/     # 导入、备份和恢复临时文件
├── backups/         # App 内最近创建的完整备份
└── network-cache/   # 可清理的只读网络漫画页面缓存

Application Support/
├── library.db       # 漫画、书源索引、引用顺序、封面、进度和设置
├── library.db.pre-v6 # 首次升级 v1.3 前自动保留的数据库快照
├── library.db.pre-v7 # 首次升级 v1.4 前自动保留的数据库快照
└── library.db.pre-v8 # 首次升级 v1.5 前自动保留的数据库快照
```

SQLite 只保存相对路径。备份恢复到另一台设备时不会依赖旧设备绝对路径。

SAF 原地挂载只在数据库保存可重建索引；原文件仍位于用户选择的目录。阅读页解码结果只进入受 120 项/96 MiB 上限约束的内存图片缓存，不创建第二份永久原图。

## 开发与验证

本机 Flutter SDK：`E:\CodexStorage\toolchains\flutter`。

```powershell
$flutterExe = 'E:\CodexStorage\toolchains\flutter\bin\flutter.bat'
& $flutterExe pub get
& $flutterExe analyze
& $flutterExe test
& $flutterExe build apk --release
```

Windows 上 Flutter AOT 对中文真实路径仍有兼容性边界。代码保留在统一中文目录；分析和测试可经英文 Junction 执行，正式 AOT 发布应在纯英文临时构建目录中完成。

## 产品与回退

- 产品行为规格：[docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md)
- v1.5 白蓝阅读器、统一动效与动态书单规格：[docs/V1.5_LIGHT_READER_MOTION_COLLECTION_DESIGN.md](docs/V1.5_LIGHT_READER_MOTION_COLLECTION_DESIGN.md)
- v1.5 发布说明：[docs/RELEASE_NOTES_V1.5.0.md](docs/RELEASE_NOTES_V1.5.0.md)
- v1.6 发布说明：[docs/RELEASE_NOTES_V1.6.0.md](docs/RELEASE_NOTES_V1.6.0.md)
- v1.4 主书架拖动、合组与阅读交互规格：[docs/V1.3.1_SHELF_DRAG_GROUP_READER_CORRECTION_SPEC.md](docs/V1.3.1_SHELF_DRAG_GROUP_READER_CORRECTION_SPEC.md)
- v1.4 发布说明：[docs/RELEASE_NOTES_V1.4.0.md](docs/RELEASE_NOTES_V1.4.0.md)
- v1.3 品牌、书架与低占用存储方案：[docs/V1.3_SHIHUAGE_BRAND_UI_STORAGE_PLAN.md](docs/V1.3_SHIHUAGE_BRAND_UI_STORAGE_PLAN.md)
- v1.3 发布说明：[docs/RELEASE_NOTES_V1.3.0.md](docs/RELEASE_NOTES_V1.3.0.md)
- v1.2 总体设计与实施结果：[docs/V1.2_SHELF_GROUPING_READER_NAVIGATION_DESIGN.md](docs/V1.2_SHELF_GROUPING_READER_NAVIGATION_DESIGN.md)
- v1.2 发布说明：[docs/RELEASE_NOTES_V1.2.0.md](docs/RELEASE_NOTES_V1.2.0.md)
- 版本回退说明：[docs/ROLLBACK.md](docs/ROLLBACK.md)
- 验收证据：[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)

Git 仓库保存源码和设计参考，完整安装包作为 GitHub Release 附件发布；两者都不会保存用户在 App 中导入的私人漫画原图。
