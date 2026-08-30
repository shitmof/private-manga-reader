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
- 阅读器右侧可拖动快速定位条与底部页码滑块，600～1000 页也可直接跳转
- 漫画自定义拖动排序、浅色/深色/跟随系统主题
- 完整 `.mangabackup` 备份与恢复；可通过系统文档选择器保存到手机、SD 卡或云盘，卸载后仍可找回
- 漫画移入回收站、恢复、永久删除；页面多选删除与无引用原图清理彼此分离
- 只读挂载 WebDAV、OPDS/Komga/Kavita、SMB/NAS；网络缓存可清，阅读进度留在本机
- Android SAF 原地挂载图片目录和 ZIP/CBZ：不复制原文件，压缩包按需直读，仅保存可重建索引和受控图片缓存
- 挂载记录连接状态、最后成功/同步时间、脱敏错误和重新认证入口
- Android 文件关联：在文件管理器点击 CBZ/ZIP/CBR/RAR/CB7/7z/CBT/TAR 可直接进入导入流程
- 本地漫画按当前编辑顺序无损导出 CBZ，并可保存到手机/云盘或调用系统分享
- 网络密码使用 Android 安全存储，不进入 SQLite、完整备份或 GitHub
- 无 App 账号、无社交、无广告、无云同步，不把原图写回系统相册

空书架不会注入演示漫画或虚假图片。设计原稿只保存在 `docs/design-reference/`，不会打包为用户内容。

## 下载 Android 安装包

- [下载拾画阁 v1.3.0 APK](https://github.com/shitmof/private-manga-reader/releases/download/v1.3.0/shihuage-v1.3.0-android.apk)
- 文件大小：66,461,238 字节（约 63.4 MiB）
- SHA-256：`C00FE7E1B244AED227E8A82EE19BCEEB7E878CE2F1520880D5AAF23E0CBC7A4C`
- 兼容 ABI：`arm64-v8a`、`armeabi-v7a`、`x86_64`

仓库是私有仓库，下载时需要登录获授权的 GitHub 账号。

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
└── library.db.pre-v6 # 首次升级 v1.3 前自动保留的数据库快照
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
- v1.3 品牌、书架与低占用存储方案：[docs/V1.3_SHIHUAGE_BRAND_UI_STORAGE_PLAN.md](docs/V1.3_SHIHUAGE_BRAND_UI_STORAGE_PLAN.md)
- v1.3 发布说明：[docs/RELEASE_NOTES_V1.3.0.md](docs/RELEASE_NOTES_V1.3.0.md)
- v1.2 总体设计与实施结果：[docs/V1.2_SHELF_GROUPING_READER_NAVIGATION_DESIGN.md](docs/V1.2_SHELF_GROUPING_READER_NAVIGATION_DESIGN.md)
- v1.2 发布说明：[docs/RELEASE_NOTES_V1.2.0.md](docs/RELEASE_NOTES_V1.2.0.md)
- 版本回退说明：[docs/ROLLBACK.md](docs/ROLLBACK.md)
- 验收证据：[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)

Git 仓库保存源码和设计参考，完整安装包作为 GitHub Release 附件发布；两者都不会保存用户在 App 中导入的私人漫画原图。
