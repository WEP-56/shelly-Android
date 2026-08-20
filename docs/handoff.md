# Shelly Android Handoff

更新日期：2026-08-20

这份文档供下一个会话直接接手。用户已经在 Android 真机上验证当前 SSH 与
xterm 终端切片，反馈为“无任何问题”。本项目没有可用的 Git 仓库，以下状态以
当前文件和 `pubspec.lock` 为准。

## 先读这些文件

1. `AGENTS.md`：产品边界、安全规则、验证限制和 `example/` 使用规则。
2. `docs/functional-spec.md`：产品行为和交互约束。
3. `docs/implementation-todo.md`：纵向切片清单；第 2 至第 7 节已完成。
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

## 当前明确未完成工作

第 7 节 SFTP 文件与传输已完成；下一个切片从 TODO 第 8 节开始：服务器状态。

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

之后依次是第 8 节服务器状态、第 9 节 Agent Provider
和受审批 write tool、第 10 节规范/搜索/生物锁，以及第 11 节生命周期和发布前
清理。

## 下一会话建议开工顺序

1. 阅读本文件、`AGENTS.md`、`functional-spec.md` 和 TODO 第 8 节。
2. 阅读并实现 TODO 第 8 节服务器状态，继续复用现有会话所有权边界。
3. 完成后只做 `dart format`、`flutter analyze`，再交给用户做真机验证。

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

当前 SSH 和终端已是真实路径，但以下功能仍有演示实现，不能在 handoff 后误认为
已完成：

- Agent 回复和 Provider：`lib/features/terminal/agent_panel.dart` 仍是演示流。
- 状态弹窗：`TerminalScreen` 中的状态卡仍是演示数据。
- 服务器状态、Agent 工具循环、生物识别和后台生命周期均未完成。

这些 mock 的清理应随对应纵向切片完成，不要在一次无关改动中顺手重构整个 UI。
