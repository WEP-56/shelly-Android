# Shelly Android

Shelly Android 是一个 Android-first 的 Flutter SSH 客户端，目标是提供清晰、
安全、适合触屏操作的远程终端体验。

远程仓库：<https://github.com/WEP-56/shelly-Android>

## 当前状态

当前已完成并在 Android 真机验证：

- SQLite 主机和应用设置持久化
- Android Keystore-backed 密码、私钥和 passphrase 存储
- `dartssh2` SSH 连接、密码/私钥认证和连接错误映射
- 未知主机指纹确认、已知指纹变化阻断和已知主机管理
- xterm 远程 shell、ANSI/UTF-8、中文输入、组合输入和全屏程序
- PTY 尺寸同步、旋转 resize、复制/全选/粘贴和 Android IME
- Termux 风格扩展按键、Ctrl/Alt 单次与锁定、导航键长按重复

便签/历史持久化、SFTP、服务器状态、Provider/Agent 工具循环、生物识别和后台
生命周期仍按实现清单逐步开发。

## 开发环境

- Flutter/Dart：以 `pubspec.yaml` 的 SDK 约束为准
- 目标平台：Android
- 不要把 `example/` 当作可运行项目或 path dependency

常用命令：

```powershell
flutter pub get
dart format lib
flutter analyze
```

按照项目 `AGENTS.md`，不要未经明确要求运行完整测试套件、Gradle/release build
或创建/管理模拟器。需要设备验证时，由开发者在自己的 Android 模拟器或真机上执行。

## 项目结构

```text
lib/
  app/                 应用入口、主题和领域模型
  core/storage/        SQLite、迁移和安全凭据存储
  core/ssh/            SSH 连接工厂、host key 和会话控制器
  core/terminal/       xterm 适配器和扩展按键定义
  features/hosts/      主机 CRUD
  features/settings/   设置和已知主机管理
  features/terminal/   终端、扩展按键、Agent 和抽屉
docs/
  functional-spec.md       产品行为规范
  implementation-todo.md   实现清单
  handoff.md               新会话接手说明
```

Widget 不得直接持有 `SSHClient`、shell 或 SFTP 句柄；连接生命周期由
`SshSessionController` 管理，终端生命周期由 `TerminalSessionAdapter` 管理。

## xterm 依赖

项目固定使用参考项目验证过的 MIT 分支提交，而不是 `example/` 中的 path：

```yaml
xterm:
  git:
    url: https://github.com/lollipopkit/xterm.dart.git
    ref: 3c53a85131794854f2d3fb5d19a700bbb337e173
```

该分支包含 Android IME、选择工具栏、粘贴、焦点和长按按键相关修复。许可证和
参考项目来源说明见本地 `example/README.md`；`example/` 本身被 `.gitignore`
忽略，不会进入产品仓库或 APK。

## 安全边界

- 始终验证 SSH host key；变化的指纹必须阻断连接。
- 密码、私钥、passphrase 和 Provider key 不得写入 SQLite、日志或 Agent 上下文。
- Agent 未来的远程写操作必须先展示完整命令并等待用户批准。
- 终端快捷键必须通过 xterm key/input API 发送控制序列，不能修改隐藏文本框。

## 继续开发

新会话请先阅读 `AGENTS.md`、`docs/functional-spec.md`、`docs/handoff.md` 和
`docs/implementation-todo.md`。默认从 TODO 第 6 节的便签与历史持久化开始，
保持现有视觉参数、SSH 生命周期和终端输入边界不变。
