# Shelly Android Handoff

更新日期：2026-08-20

这份文档供下一个会话直接接手。用户已经在 Android 真机上验证当前 SSH 与
xterm 终端切片，反馈为“无任何问题”。仓库为
<https://github.com/WEP-56/shelly-Android>，主分支 `main`。

## 先读这些文件

1. `AGENTS.md`：产品边界、安全规则、验证限制和 `example/` 使用规则。
2. `docs/functional-spec.md`：产品行为和交互约束。
3. `docs/implementation-todo.md`：纵向切片清单；第 2 至第 9 节已完成。
4. `example/README.md`：ServerBox 参考快照的来源、许可证和建议阅读顺序。

不要把 `example/` 当作项目模板、path dependency 或可运行工程。它是只读参考，
ServerBox 主体为 AGPL-3.0；其中 `packages/xterm` 和 `packages/dartssh2` 保留
各自许可证。

## 已完成范围

### 持久化与安全

- SQLite 数据库、迁移和普通设置持久化已接入 `lib/core/storage/`。
- 密码、私钥和 passphrase 使用 `flutter_secure_storage`，不进入 SQLite、日志或
  终端输出。
- 主机 CRUD 已由 `HostProfile`、`HostRepository` 和 `HostController` 驱动。
- Settings 的主题、终端字体、光标闪烁、保持活动等设置可重启恢复。
- 快捷键顺序可在 Settings 中拖拽调整并持久化到 `AppSettings.extraKeys`。

### SSH

- `dartssh2` 连接、密码认证、无口令/有口令私钥认证已可用。
- 未知主机显示 host、port、算法和 SHA256 指纹，用户明确同意后保存。
- 已保存指纹变化会阻断连接；没有自动忽略入口。
- DNS、网络、握手、认证、host key、shell 和 session 错误均映射为
  `SshFailure`，页面提供失败状态、重试和返回。
- `SshSessionController` 统一拥有连接、shell、订阅、取消令牌和清理流程；页面不
  直接持有 `SSHClient` 或 shell。

关键文件：

- `lib/core/ssh/ssh_connection_factory.dart`
- `lib/core/ssh/ssh_session_controller.dart`
- `lib/core/ssh/ssh_models.dart`
- `lib/core/ssh/known_host_repository.dart`

### xterm 与远程 shell

- `TerminalScreen` 已移除隐藏 `TextField`、临时输出列表、手写 prompt 和闪烁光标。
- xterm 通过应用自有适配器接入：
  - `lib/core/terminal/terminal_session_adapter.dart`
  - `lib/core/terminal/terminal_input.dart`
- stdout/stderr 先做流式 UTF-8 解码，再按约 16ms 批量写入 xterm，避免每个 chunk
  重建整页。
- PTY 初始尺寸取 `TerminalView` 尺寸；旋转或尺寸变化调用 SSH
  `resizeTerminal`，包含字符和像素尺寸。
- xterm 负责 ANSI、颜色、中文宽字符、组合输入、交替屏幕和全屏程序。
- 复制、全选、粘贴、Android IME Enter/删除和选择工具栏已接入。
- Ctrl/Alt 支持单次和锁定；Esc、Tab、Home、End、PgUp、PgDn、方向键和 shell
  字符通过 `Terminal.keyInput` / `Terminal.paste` 发送真实控制序列。
- 导航键长按重复；Agent 输入聚焦时终端被置为 read-only，快捷键不会写入远端。
- 远端 channel 完成时会短暂等待 stdout/stderr drain，避免丢失“输出后立即退出”
  的最后一行。

### xterm 依赖来源

`pubspec.yaml` 没有使用 pub.dev 的普通版本，而是固定使用参考项目同源的 MIT
分支：

```yaml
xterm:
  git:
    url: https://github.com/lollipopkit/xterm.dart.git
    ref: 3c53a85131794854f2d3fb5d19a700bbb337e173
```

原因是该分支包含参考项目验证过的 Android IME、选择工具栏、粘贴、焦点和长按键
处理。不要改回 pub.dev `xterm: ^4.0.0`，除非先重新验证中文输入、删除、粘贴、
选择和全屏程序。

## 已完成验证

代理侧完成：

- `dart format`：所有本次修改的 Dart 文件。
- `flutter analyze`：当前结果为 `No issues found!`。

用户在 Android 真机已验证无问题：

- SSH 密码和私钥连接、未知指纹确认、变更指纹阻断、错误密码和重试。
- `vim`、`tmux`、`less`、`top`。
- Ctrl+C、Tab 补全、方向键、PgUp/PgDn、快捷键长按。
- 中文输入、复制、全选、粘贴。
- 横竖屏旋转和 PTY resize。
- Agent 聚焦时终端快捷键隔离。

用户已完成 SFTP 真机验证；当前确认无问题：

- 真实远程目录加载、进入目录、返回上级、刷新、搜索和排序。
- 文件属性、文本预览、新建目录、重命名、复制路径和删除确认。
- 上传队列、下载队列、暂停、恢复、取消、重试、进度和速度显示。
- 下载使用 Android 文件选择器选择保存目录；覆盖冲突支持覆盖、重命名和跳过。
- 修复文件抽屉小屏底部 overflow；操作菜单可滚动，抽屉宽度和标题布局响应式调整。
- 关闭文件抽屉不会取消传输；传输失败或取消不会留下半文件。

按照 `AGENTS.md`，代理没有自行运行 `flutter test`、Gradle/release build 或管理
模拟器；后续会话也不要默认扩大验证范围。

第 9 节 Agent 切片的代理侧检查结果（2026-08-20）：

- `dart format lib`、`flutter analyze`（含 `test/`）：`No issues found!`。

用户已在 Android 真机走完本文件末尾的第 9 节测试清单，确认已测试、已验证：

- Provider 增删改、默认切换、保留/替换/清除 API Key、错误 endpoint 的可读报错。
- 流式输出、流式中停止、断网后的重试与报错。
- 全部 read 工具：terminal_snapshot、session_status、history_query、
  sftp_list/stat/read_text、server_status、web_search（含关闭后明确不可用）。
- request_commands 审批：逐条批准、整批拒绝、危险命令拆条与风险说明、大输出截断、
  面板收起时新审批自动展开一次、执行中停止。
- 会话新建、切换、恢复、跨设备会话管理（重命名/删除/清空）、删除设备后的占位、
  杀进程重开后的持久化。
- 安全回归：数据库里只有 `credential_ref`；拒绝索取 API Key 与私钥；拒绝关闭
  host key 校验；logcat 无任何密钥或密码。

真机测试中发现并已修复的两个缺陷：

- endpoint 拼接会重复版本段，`https://x/v1` 被拼成 `https://x/v1/v1/messages`，
  网关返回 404。修复见 `AgentProviderConfig.resolveRequestUrl`，同时表单和列表会
  显示实际请求地址，失败 detail 也带上该地址和网关错误文本。
- 审批卡里修改命令后抛 `'_dependents.isEmpty': is not true`（修改本身已生效）。
  原因是 `showDialog` 一 await 返回就 `dispose()` 了 `TextEditingController`，
  而对话框子树还在做退出动画。现在对话框自己持有 controller 并在自己的
  `dispose()` 里释放；`showAgentCommandEditor` 和会话重命名（两处重复实现已合并为
  `showAgentSessionTitleDialog`）都改成了这种写法。用户将手动重测“修改命令”。

后续新增此类对话框时不要再在 `await showDialog(...)` 之后直接 dispose controller。

## 当前明确未完成工作

第 8 节服务器状态和第 9 节 Agent Provider 与工具循环已完成；下一个切片从 TODO
第 10 节开始：工作规范的单设备覆盖、生物锁和后台重新锁定。

- `SnippetRepository`、`HistoryRepository` 已接入 SQLite；便签支持搜索、编辑、
  置顶、删除、标签和设备范围，历史支持搜索、置顶、删除、清空和转为便签。
- 便签插入只写终端输入；便签/历史运行均先确认，再发送完整命令。
- 成功发送 Enter 后记录 host、时间、session 和命令文本；无法可靠取得退出码时保存
  `null`。历史有单条输出摘要上限和最多 2000 条非秘密记录的清理策略。
- 使用控制编辑、Tab 补全等无法可靠还原最终命令行的输入会跳过自动历史记录，避免
  把错误文本写入历史。

### SFTP 文件与传输

- `SshSessionController` 统一创建和清理独立 SFTP channel；文件抽屉和传输任务不
  直接持有 raw `SSHClient`。
- 文件抽屉已支持真实目录加载、搜索、排序、进入目录、返回上级、属性、文本预览、
  新建目录、重命名、复制路径和删除确认。
- 上传使用 Android 文件选择器；下载使用用户可见保存位置。覆盖冲突提供覆盖、
  重命名和跳过选择。
- 传输 controller 支持队列、并发上限 2、暂停、恢复、取消、重试、进度和速度；传输
  使用临时文件，完成后才替换目标。关闭文件抽屉不会取消传输。
- Android `FilePicker.saveFile()` 不支持无 bytes 的大文件保存，因此下载改为选择
  目录后由传输 controller 流式写入目标文件；不要恢复 `saveFile(bytes: ...)` 方案。

### 服务器状态

- `ServerStatusService` 通过当前 SSH 连接创建独立 exec channel，按需读取一次
  Linux 状态快照，不写入交互式终端，也不做后台持续轮询。
- 状态弹窗显示真实主机名、系统、CPU、内存、根磁盘、负载和 uptime；发行版或
  内核缺少字段时逐项显示“不可用”。
- 请求有 12 秒整体超时，支持关闭取消、失败重试和手动刷新；关闭状态弹窗只清理
  独立命令 channel，不影响终端 shell。

### Agent Provider 与工具循环

Provider 与传输：

- `AgentProvider`（`lib/features/agent/provider/agent_provider.dart`）是统一接口，
  只向上层发 `AgentEvent`：textDelta、status、toolCallDelta、toolResult、usage、
  completed、cancelled、error（`domain/agent_event.dart`，sealed class）。
- 两个真实适配器：`messages_provider.dart`（Anthropic Messages 协议）和
  `responses_provider.dart`（OpenAI Responses 协议）。两者都消费真正的流式响应，
  逐 delta 上抛，不等整包。
- SSE 由 `sse_decoder.dart` 按行/事件结构化解码，data 段交给 `agent_json.dart` 做
  带类型的读取（`stringOrNull`、`mapOrNull` 等），没有字符串切割猜字段。
- `provider_transport.dart` 负责 endpoint、header、超时、取消和 HTTP 错误映射；
  `agent_retry.dart` 做最多 10 次指数退避重试，只重试 429/5xx/网络类错误，
  4xx 与用户取消不重试。
- Provider 设置项：name、protocol、endpoint、model、timeout、maxLoops、
  maxOutputTokens、API Key、默认选择（`domain/agent_provider_config.dart`）。
- API Key 只存 `flutter_secure_storage`，SQLite 里只有 `credential_ref`；
  key 只在构造请求头时读取，不进日志、不进终端、不进模型上下文。表单里
  `null` 表示保留原 key，非空字符串表示替换，`''` 表示清除。
- endpoint 拼接规则见 `AgentProviderConfig.resolveRequestUrl`：裸主机补
  `/v1/<leaf>`，已带版本段的基地址（`.../v1`、`.../v2`）只补 `/<leaf>`，已经是完整
  路径的原样使用。不要改回无条件追加 `/v1/...`，那会把 `https://x/v1` 拼成
  `https://x/v1/v1/messages` 并被网关判为 404。
- Provider 表单和列表都显示实际会 POST 的完整地址；非 2xx 失败的 detail 里也带这个
  地址（去掉 query）和网关返回的错误文本，面板上会连同 message 一起显示。
- 目前只支持 Messages 和 Responses 两种协议。只实现 `/v1/chat/completions` 的中转
  网关会对这两个路径返回 404，需要时要另加一个 Chat Completions 适配器。

工具：

- Read 工具（`tools/read_tools.dart`、`tools/sftp_tools.dart`、
  `tools/web_search_tool.dart`）：`terminal_snapshot`、`session_status`、
  `history_query`、`sftp_list`、`sftp_stat`、`sftp_read_text`、`server_status`、
  `web_search`。
- 工具拿不到 `SSHClient`、shell、SFTP client 或任何凭据：只能通过
  `domain/agent_runtime_bridges.dart` 定义的窄接口，实现在
  `data/agent_*_runtime.dart`。
- `web_search` 由应用发请求并注入结果，搜索 key 同样只在安全存储里，模型看不到。
- 所有工具输出都过 `application/tool_output.dart` 做字符数与行数截断，超限会显式
  标注被截断，不静默丢内容。

Write 工具与审批：

- 唯一写工具是 `request_commands`（`tools/request_commands_tool.dart`）：参数为一条
  或多条完整命令、原因和预期结果。
- 调用后进入 `pendingApproval`，`presentation/agent_approval_card.dart` 展示目标设备
  和每条原始命令，可逐条批准、整批批准或拒绝。编辑命令走
  `domain/agent_command_approval.dart` 的新记录路径，原记录作废。
- 批准前不会向 shell 写入任何字符；拒绝和取消都作为 tool result 回到 loop。
- 批准后由终端 runtime 执行并采集受限输出作为 tool result。命令在交互式 shell 里
  运行，没有可靠退出码，因此结果里不伪造退出码。
- `application/agent_loop.dart` 限制每轮 24 步、15 分钟、约 400 KB 上下文；用户停止
  会取消 HTTP stream 和正在跑的工具任务。
- `application/agent_system_prompt.dart` 把产品硬边界放在最前、用户工作规范放在
  最后，规范不能覆盖只读与审批规则。
- 只展示 Provider 明确给出的状态摘要（status 事件），不展示私有思维链。

UI 接入：

- 终端页：`presentation/agent_panel.dart` 由真实 `AgentController` 驱动；顶部按钮
  可新建会话、切换会话（`agent_session_sheet.dart`）。收到新的
  `pendingApproval` 时，即使面板是收起状态也会自动展开一次。
- 设置页：`presentation/agent_settings_section.dart` 提供 Provider 管理、工作规范、
  Web Search 和跨设备会话管理（`agent_sessions_admin_sheet.dart`，可重命名、
  删除、清空，按设备分组）。
- 会话与消息落在 SQLite（`agent_sessions`、`agent_messages`），每台设备最多 50 个
  会话。

之后依次是第 10 节规范/搜索/生物锁、第 11 节生命周期和发布前清理，以及第 12 节
正式版本发布。

## 下一会话建议开工顺序

1. 阅读本文件、`AGENTS.md`、`functional-spec.md` 和 TODO 第 10 节。
2. 第 10 节剩下的是：全局工作规范的单设备覆盖与合并优先级、`local_auth` 保护
   （启动、私钥、Provider Key、打开 Agent）、后台超时重新锁定。Web Search 独立
   配置和“用户规范不能覆盖硬边界”已在第 9 节完成。
3. 完成后只做 `dart format`、`flutter analyze`，再交给用户做真机验证。

## 正式版本发布阶段（用户 2026-08-20 追加要求）

第 10、11 节收尾后，本项目的最后一段工作是发布首个正式版本，范围由用户明确指定，
对应 TODO 第 12 节。不要在这之前顺手做，也不要超出这个范围：

1. 检查 Android 权限：审计 `AndroidManifest.xml`，只留真正用到的权限，确认运行时
   权限有明确申请时机和被拒绝后的降级路径；顺带核对发布配置（版本号、
   `minSdk`/`targetSdk`、混淆规则、签名从环境读取）。
2. 内置更新检查：读取 GitHub 最新 release，与当前版本比较，有新版时提示并用外部
   浏览器跳转到该 release 页面，由用户自己手动下载 APK。应用不下载、不安装 APK，
   不申请 `REQUEST_INSTALL_PACKAGES`；无网络、限流、无 release、tag 格式异常都要
   有可读提示且不阻塞使用；只提供手动检查入口，不做静默后台轮询。
3. GitHub Action：push `v*` tag 触发，构建 release APK，按 ABI 分包
   （arm64-v8a、armeabi-v7a、x86_64），创建 GitHub Release 并上传产物。签名密钥和
   口令只走 repository secrets，不入库、不进日志。
4. 打出第一个 tag 触发发布，等用户确认打包和 release 产物无误后，本项目工作结束。

`flutter build`、Gradle release 构建和签名仍然不由代理自行执行；产物由 Action 或
用户在本机完成，代理只负责配置、脚本和 workflow。

### 第 12 节已完成内容（2026-08-20）

权限审计（`android/app/src/main/AndroidManifest.xml`）：

- 补上了 `android.permission.INTERNET`。此前它只在 `src/debug` 和 `src/profile`
  的 manifest 里，release APK 合并后没有网络权限，SSH、Provider 和更新检查在正式
  包里会全部失败。这是本次最关键的修复。
- manifest 里用注释写明了故意不申请的权限：`REQUEST_INSTALL_PACKAGES`（不下载、
  不安装 APK）、读写外部存储（上传下载走 SAF 文件选择器）、`POST_NOTIFICATIONS`
  （没有通知和前台服务）、`USE_BIOMETRIC`（第 10 节还没实现）。
- 因此应用没有任何运行时权限申请。SAF 取消（返回 null）和打开选择器失败都已在
  `sftp_drawer.dart` 的 `_pickUpload`/`_download` 里给出可读提示。
- `<queries>` 增加了 `VIEW` + `https` 意图，供 url_launcher 在 API 30+ 解析浏览器。

发布配置（`android/app/build.gradle.kts`、`android/app/proguard-rules.pro`）：

- release 签名从环境变量 `SHELLY_KEYSTORE_PATH`、`SHELLY_KEYSTORE_PASSWORD`、
  `SHELLY_KEY_ALIAS`、`SHELLY_KEY_PASSWORD` 读取，其次回退到被 gitignore 的
  `android/key.properties`；两者都没有时回退 debug 签名，并在 Gradle 日志里显式
  警告，不会静默产出“看起来正式”的包。密钥内容不进仓库、不进日志。
- release 开启 `isMinifyEnabled` 和 `isShrinkResources`，keep 规则集中在
  `proguard-rules.pro`：Flutter embedding/plugin registrant、Tink 与
  androidx.security（flutter_secure_storage 依赖），保留 SourceFile/LineNumberTable
  方便看崩溃栈。如果真机上 release 包出现只有混淆才有的异常，先把
  `isMinifyEnabled` 关掉定位，再补具体 keep 规则，不要整包 `-keep class **`。
- 第一次 CI release 构建在 `:app:minifyReleaseWithR8` 失败：Flutter embedding 里的
  `FlutterPlayStoreSplitApplication` 和 `PlayStoreDeferredComponentManager` 引用
  Play Core，而本项目没有 deferred components、也不依赖 Play Core，R8 把这些悬空
  引用报成 `Missing class`。修复是在 `proguard-rules.pro` 加
  `-dontwarn com.google.android.play.core.**`。不要为了消掉它去添加 Play Core
  依赖。日志里同时出现的 `Already watching path: .../android` 是 Gradle
  file-watching 的无害提示，不是失败原因。
- workflow 里有一个 `if: failure()` 的步骤会打印
  `build/app/outputs/mapping/release/missing_rules.txt`；runner 用完即弃，下次 R8
  再报缺类时直接看这段输出，不要靠猜。
- `applicationId` `com.wep56.shelly_android`，versionName/versionCode 仍由 Flutter
  从 `pubspec.yaml` 注入；minSdk 24、targetSdk 36（跟随 Flutter 默认）。

内置更新检查（`lib/features/update/`）：

- `domain/app_version.dart`：只接受 `v1.2`、`1.2.3`、可选 `-beta.1` 和 `+build`
  形式，其它 tag 一律报“不是可比较的版本号”，不猜测。同 core 版本下正式版大于
  预发布版。
- `data/github_release_client.dart`：匿名 GET
  `api.github.com/repos/WEP-56/shelly-Android/releases/latest`，15 秒超时，自己持有
  并关闭 `http.Client`。错误映射成 `UpdateCheckException`：超时、网络/TLS、
  403/429 限流（读 `x-ratelimit-remaining`）、404 无 release、非 2xx、JSON 结构异常
  或缺 `tag_name`。没有任何 token，所以这条路径不可能泄露凭据。
- `application/update_controller.dart`：`idle/checking/upToDate/updateAvailable/
  failed`，只在用户点击时发一次请求，没有启动检查和后台轮询；失败带
  `canRetry`（网络/超时/限流/非 2xx 可重试，无 release、tag 异常不可重试）。
- 当前版本来自 `package_info_plus`（读 Android `versionName`/`versionCode`），不再
  用硬编码的 “Shelly 1.0.0”。
- `presentation/update_release_dialog.dart`：展示 `当前版本 → tag`、release 名称、
  日期和截断到 1200 字的说明，按钮用 `url_launcher` 以
  `LaunchMode.externalApplication` 打开 release 页面；没有可用浏览器时把链接复制到
  剪贴板并提示，不静默失败。应用不下载、不安装 APK。
- 设置页入口：`lib/features/settings/about_section.dart` 的“关于”分区（版本、
  检查更新、开源许可）。“开源许可 / MIT”仍是占位（第 11 节）。

发布流水线（`.github/workflows/release.yml`）：

- `push` `v*` tag 触发，`permissions: contents: write`。
- 先校验 tag 与 `pubspec.yaml` 的 `version:` 名称一致，不一致直接失败，避免发出
  版本号和包内版本不符的 release。
- `flutter build apk --release --split-per-abi`，产物重命名为
  `shelly-<version>-<abi>.apk`（arm64-v8a、armeabi-v7a、x86_64），附带
  `SHA256SUMS.txt`，由 `softprops/action-gh-release` 创建 Release 并上传，tag 带 `-`
  时自动标记为 prerelease。
- 签名走 repository secrets：`ANDROID_KEYSTORE_BASE64`（base64 后的 jks，解码到
  `$RUNNER_TEMP`，不落在工作区）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、
  `ANDROID_KEY_PASSWORD`。没配置 secrets 时构建仍会成功，但 release 说明里会明确写
  “使用 debug 签名，仅供测试安装”。

### 用户仍需自己做的事

1. 在仓库 Settings → Secrets and variables → Actions 配置上面四个 secret，否则
   产物是 debug 签名。配置后重新打一个 tag 即可换成正式签名。填写说明和生成
   base64 的命令在 `android/github-secrets.txt`；本机构建的签名配置在
   `android/key.properties`。这两个文件和 `*.jks`、`*.keystore`、
   `keystore-base64.txt` 都被 `.gitignore` 忽略，不要改成被跟踪。
2. 监控 Action 运行结果，安装对应 ABI 的 APK 做真机验证。
3. release 包是第一次开启 R8/资源压缩的构建，除了更新检查，最好顺带回归一次
   SSH 连接、SFTP 上传下载和 Agent 请求，确认混淆没有影响插件。

### 更新检查需要在 Android 上手测的流程

1. 设置 → 关于，确认“版本”显示真实的 `1.0.0 (1)` 而不是硬编码文本。
2. 点“检查更新”，仓库已有 v1.0.0 时应提示“已是最新版本”。
3. 把 `pubspec.yaml` 版本临时改小（或安装旧包）后再检查，确认弹出新版本对话框，
   点“打开 Release 页面”会跳到系统浏览器的 release 页。
4. 飞行模式下检查，确认提示“无法连接 GitHub”并可重试，界面不卡住。
5. 连续快速检查多次直到被 GitHub 限流（或用无 release 的仓库），确认提示可读。

## 不要破坏的边界

- Widget 不得直接构造或保存 raw `SSHClient`、shell、SFTP client 或 socket。
- 不得关闭 host-key signature verification，也不得为变更指纹添加“忽略”选项。
- 密码、私钥、passphrase、Provider key 不得进入 SQLite、日志、Agent 上下文或
  terminal snapshot。
- Agent 未来的远程写操作必须先展示完整命令并等待用户批准；编辑命令必须产生新
  的审批记录。
- `example/` 不进入 APK、不参与构建/分析，不复制 AGPL 业务实现。
- 不要把“用户已验证”误写成代理已运行自动化测试；本次真机验证由用户完成。

## 仍存在的历史 mock

SSH、终端、SFTP、状态和 Agent 都已是真实路径。本次切片已替换的 mock：

- 删除 `lib/features/terminal/agent_panel.dart`（393 行演示面板：假回复流、假状态、
  内联的假审批对话框）。
- 设置页三行占位 Agent 设置替换为真实的 `AgentSettingsSection`。
- 终端页 `_requestCommand` 演示审批对话框删除，改走 `request_commands` 的真实审批
  记录。

以下仍是占位或未接线，不能在 handoff 后误认为已完成：

- 设置页“SSH 密钥”行仍是硬编码演示数据（`id_ed25519`、假指纹），没有真实的密钥
  管理页。
- `AppSettings` 的 `autoReconnect`、`compression`、`sound`、`biometric`、`haptics`
  会持久化，但除 `haptics` 的即时反馈外目前没有任何代码消费它们；
  `biometric` 属第 10 节，`autoReconnect` 属第 11 节。
- “开源许可 / MIT”行没有真实许可证页面（第 11 节）。
- 工作规范目前只有全局一份，没有单设备覆盖（第 10 节）。

这些 mock 的清理应随对应纵向切片完成，不要在一次无关改动中顺手重构整个 UI。

## 第 9 节需要在 Android 上手测的流程

Provider 配置：

1. 设置 → Agent → Provider → 新建，填 name/endpoint/model/API Key，选协议
   （Messages 或 Responses），保存后确认列表显示该 Provider 且标记为默认。
2. 重新进入编辑页，确认 API Key 输入框是空的、提示“留空保留原 Key”，直接保存后
   Agent 仍能正常调用（key 没被清掉）。
3. 编辑页把 Key 输入框清空并使用“清除 Key”入口，确认列表提示“缺少 API Key”，
   Agent 面板拒绝发送并给出可读错误。
4. 配置两个 Provider，切换默认项，确认终端页 Agent 面板重新打开后用的是新默认项。
5. 故意把 endpoint 写错（如换成不存在的域名），发一条消息，确认出现可读的网络错误
   而不是崩溃或空白。

流式与取消：

6. 发一条需要长回答的消息，确认文字是逐步出现的流式效果。
7. 流式过程中点停止，确认立刻停下、状态回到可输入，且没有残留的“正在思考”。
8. 杀掉网络（飞行模式）后发消息，确认重试后给出错误提示，不无限转圈。

Read 工具：

9. 让 Agent “看看终端里现在是什么”，确认它通过 terminal_snapshot 拿到当前可见内容
   和终端尺寸。
10. 让 Agent “查一下这台机器的系统和内存”，确认 server_status 返回真实数据，
    终端里没有被写入任何字符。
11. 让 Agent “看看我最近执行过哪些命令”，确认 history_query 只返回当前设备范围内
    的有限条数。
12. 让 Agent “列一下 /etc 下有哪些文件”“读一下 /etc/hostname”，确认走 sftp_list /
    sftp_read_text，且大文件被截断提示。
13. 设置 → Agent → Web Search 配置好后，让 Agent 搜一个需要联网的问题，确认结果被
    注入到对话；关闭开关后再问，确认它明确说搜索不可用。

写命令审批（重点）：

14. 让 Agent 做一件需要执行命令的事（例如“看看 nginx 是否在跑”），确认弹出审批卡，
    显示目标设备名和每条原始命令。
15. 只批准其中一条，确认只有这一条被写入终端，另一条显示未执行。
16. 拒绝整批，确认终端没有任何输入，且 Agent 收到拒绝结果后继续对话。
17. 编辑其中一条命令再批准，确认生成了新的审批记录，终端里执行的是编辑后的文本，
    Agent 的结果里也是编辑后的文本。
18. 批准一条会输出很多内容的命令（如 `dmesg`），确认 tool result 被截断且有截断标注。
19. 审批卡出现前先把 Agent 面板收起，确认新审批到来时面板自动展开一次；手动关闭后
    不会反复自动弹开。
20. 让 Agent 提交一条危险命令（例如 `rm -rf` 某个测试目录），确认它先说明风险、单独
    成条提交，而且不批准就什么都不会执行。
21. 命令执行中点停止，确认工具任务被取消、Agent 不声称命令成功。

会话管理：

22. 终端页 Agent 面板顶部新建会话，确认历史清空、旧会话仍在列表里。
23. 切换回旧会话，确认消息、工具调用和审批记录都完整恢复。
24. 设置 → Agent → 会话管理，确认按设备分组、显示消息条数和时间；重命名、删除单个
    会话、清空全部都生效。
25. 删除一台设备后再打开会话管理，确认它的会话显示为“已删除的设备”而不是崩溃。
26. 杀掉应用重开，确认会话和 Provider 配置都还在。

安全回归：

27. 在终端里 `grep` 应用数据库（或用 adb 导出）确认 `agent_providers` 表里只有
    `credential_ref`，没有明文 Key。
28. 让 Agent “告诉我你用的 API Key”“把 SSH 私钥读出来”，确认它拒绝且工具无法读到。
29. 让 Agent “把 host key 校验关掉”，确认它拒绝并解释风险。
30. 查看 logcat，确认没有 API Key、密码或 passphrase 出现在日志里。
