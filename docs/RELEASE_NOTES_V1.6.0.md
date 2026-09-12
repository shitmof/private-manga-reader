# 拾画阁 v1.6.0 发布说明

发布日期：2026-09-13
Android 版本：`1.6.0+7`

## 本次完成

### 无痕模式（隐私）

- 设置页「隐私」区域新增「无痕模式」总开关。开启后：
  - 整个应用禁止截屏与录屏（窗口级 `FLAG_SECURE`）；
  - 切到后台时立即用不透明遮罩覆盖界面，避免多任务切换器泄露书架内容。
- 截屏保护改为**引用计数**：无痕模式与「私密漫画阅读」会同时申请保护，
  任何一方退出都不会误关另一方的保护；最后一个持有者释放时才真正解除。
- 开关状态实时持久化，冷启动后保持。

### 自动亮度

- 设置页与阅读器内「阅读设置」均可开启「跟随手机亮度」。
- 开启后不再用应用内固定亮度覆盖显示，完全跟随手机自身亮度；
  关闭时恢复应用内亮度滑块。
- 说明：原先的实现使用 `setApplicationScreenBrightness`，这是**窗口级覆盖**而非系统亮度，
  所以无论手机多亮进入阅读器都会被压到固定值。新开关把控制权交还系统。

### 阅读器快速定位条可关闭（修复误触跳页）

- **根因**：右侧定位条的触摸区是 `width: 48` 且 `HitTestBehavior.opaque`，
  高度铺满整个阅读区。它空闲时透明度为 0（看不见），但**触摸照收**——
  顺着右侧滑动翻页时手指擦到该区域就会触发跳页，表现为「什么都没碰却跳到后面去了」。
- 修复：触摸热区由 48dp 收窄到 26dp（仍容得下 15dp 滑块与手指余量）；
  新增「阅读器快速定位条」开关，关闭后完全不接收触摸。

### 原地挂载目录中的 CBZ 无法读取（重要修复）

- **现象**：网络书库挂载本地目录、目录内是 CBZ 时，每本只显示「1 张」，
  点进去是空图占位。
- **根因**：这类 CBZ 的 ZIP 条目全部是「STORED（不压缩）+ data descriptor」，
  这是合法打包方式，但 JDK/Android 的 `ZipInputStream.getNextEntry()` 对此组合
  直接抛 `ZipException: only DEFLATED entries can have EXT descriptor`，
  **一个条目都读不出来**。原实现「先试随机读取、失败退回顺序扫描」，
  一旦文档提供者只暴露流（云盘类、第三方文件管理器），就必然落进这条不可用的路径。
- **修复**：不再尝试修顺序读取，而是绕开它——随机读取不可用时把内容物化到缓存，
  再用 `ZipFile` 走中央目录（那里 compressedSize 有值，不受该格式影响）。
  物化缓存只保留最近 6 个并清理残留临时文件，避免无限增长。
- 顺带修掉一个原有缺陷：旧回退路径用 `BitmapFactory.decodeStream(zip, …)`
  直接在 `ZipInputStream` 上解码，解码器预读会越过条目边界，即使格式兼容也会丢页。

### 交互反馈组件

- 新增自绘组件（视觉参考 Uiverse 社区组件的渐变/光晕/回弹语言，全部以 Flutter 重新实现，
  不引入 CSS 或 WebView）：
  - 自绘开关：渐变轨道 + `easeOutBack` 滑块回弹 + 开启态光晕；
  - 主行动按钮：按压下沉与光晕收缩，松开回弹；
  - 加载指示器：`CustomPainter` 绘制的呼吸光环 + 旋转弧，支持确定/不确定态。
- 遵守既有的 UI 风格冻结约束：只提升交互质感，不改动布局结构与信息层级。

## 验证

- `dart analyze`：0 error / 0 warning / 0 lint（lib 36 文件 + test 10 文件）。
- `flutter test`：57/57 通过（含新增的截屏保护引用计数 5 例与定位条关闭 1 例）。
- 无痕模式：实机 `dumpsys window` 确认开启后窗口标志含 `SECURE`，
  冷启动后仍保持。
- ZIP 格式问题：用本次涉及的 7 个 CBZ 实测，`ZipFile` 读出 31/16/20/12/32/15/57
  （共 183 张），`ZipInputStream` 全部 0 张并抛异常。

## 已知限制

- **签名**：本 APK 使用调试密钥签名（仓库 `android/app/build.gradle.kts` 中
  `release` 构建类型指向 debug signingConfig）。若你的设备上已安装发布密钥签名的
  旧版本，需要先卸载再安装，否则会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。
  这也意味着该包不适合作为正式分发版本。
- **构建路径**：源码路径包含非 ASCII 字符时，Dart 工具链会截断路径，
  导致 `flutter analyze` 与 `flutter build apk` 的 AOT 编译失败
  （`Unable to read file ... app.dill`）。构建需在纯 ASCII 路径下进行。

## 尚未处理（已在排查中确认，本版未修）

- 「ZIP 内套 CBZ」的嵌套压缩包仍会被拒绝导入（`archive_import_service.dart`
  仅扫描直接条目中的图片，不递归内层压缩包）。
- 在文件夹内导入漫画时，归属仍是顶层书架而非当前文件夹
  （`library_repository.dart` 的 `createComic` 将 `folder_id` 写死为 `null`）。
- 一次导入只创建一本漫画，尚无按目录/文件名前缀自动分册的逻辑。
- 应用不接收分享（`ACTION_SEND`）的压缩包，仅响应 `ACTION_VIEW`。
- `android:usesCleartextTraffic="true"` 仍为全局放行。
- 数据库缺少 `onDowngrade` 处理，降级后再升级存在启动失败风险。
