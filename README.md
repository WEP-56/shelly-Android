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
- 便签与命令历史持久化、搜索、置顶和互转
- SFTP 文件浏览、属性/预览/重命名/删除，以及上传下载队列（暂停、恢复、重试）
- 按需服务器状态快照（系统、CPU、内存、磁盘、负载、uptime）
- Agent Provider（Messages / Responses 流式协议）、只读工具集，以及唯一写工具
  `request_commands` 的逐条命令审批
- 手动检查 GitHub 最新 release 并跳转浏览器下载

生物识别锁、单设备工作规范和后台生命周期重连仍按实现清单逐步开发，详见
`docs/implementation-todo.md` 第 10、11 节。

## 安装

正式版本由 GitHub Action 在推送 `v*` tag 时构建，按 ABI 分包上传到
[Releases](https://github.com/WEP-56/shelly-Android/releases)。请下载与设备
架构匹配的 APK（多数设备是 `arm64-v8a`）并手动安装；应用内的“检查更新”只会
打开 release 页面，不会自行下载或安装 APK。

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
  features/settings/   设置、已知主机和关于/更新入口
  features/terminal/   终端、扩展按键和抽屉
  features/snippets/   便签
  features/history/    命令历史
  features/sftp/       SFTP 浏览与传输
  features/agent/      Provider、工具循环与审批
  features/update/     GitHub release 检查
docs/
  functional-spec.md       产品行为规范
  implementation-todo.md   实现清单
  handoff.md               新会话接手说明
.github/workflows/
  release.yml              push v* tag 时构建并发布 APK
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

## 发布

- `pubspec.yaml` 的 `version:` 是唯一版本来源；Gradle 会把它注入
  `versionName`/`versionCode`。
- 发布新版本：改 `pubspec.yaml` 的 `version:`，提交后推一个同名 `v*` tag
  （例如 `1.0.1+2` 对应 `v1.0.1`）。workflow 会校验 tag 与版本名一致，不一致直接
  失败。
- release 签名只从 repository secrets 读取（`ANDROID_KEYSTORE_BASE64`、
  `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`），
  密钥和口令不入库、不进日志。未配置时构建仍会成功，但产物是 debug 签名，
  release 说明里会明确标注。
- 本地构建 release 包时，签名信息从环境变量 `SHELLY_KEYSTORE_PATH`、
  `SHELLY_KEYSTORE_PASSWORD`、`SHELLY_KEY_ALIAS`、`SHELLY_KEY_PASSWORD` 读取，
  或放在被 gitignore 的 `android/key.properties`。

## 继续开发

新会话请先阅读 `AGENTS.md`、`docs/functional-spec.md`、`docs/handoff.md` 和
`docs/implementation-todo.md`。TODO 第 2 至第 9 节和第 12 节已完成，默认从第 10 节
（单设备工作规范、`local_auth` 生物锁、后台重新锁定）开始，保持现有视觉参数、
SSH 生命周期和终端输入边界不变。
