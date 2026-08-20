# Shelly Android 实际功能实现 TODO

状态：纯前端原型已完成，下一阶段开始接入真实数据和远程能力。

本文件是实现顺序和验收清单。产品行为以 `functional-spec.md` 为准，视觉与
交互以 `md3-ssh-client-mockup/` 为准，工程和安全约束以根目录 `AGENTS.md`
为准。`example/` 只用于查阅 ServerBox 的 API 使用经验，不复制代码、不参与
构建和分析。

## 0. 当前基线

- Flutter 工程仅支持 Android，应用名和启动图标已配置为 Shelly。
- Server、Settings、Terminal、Agent、状态、便签、历史和文件抽屉均为前端演示。
- mock 数据集中在 `lib/app/models.dart`、`HomeShell`、`TerminalScreen` 和
  `terminal_drawers.dart`，没有持久化、SSH、SFTP 或真实 Provider。
- 终端输出已使用 Android 原生选区菜单；便签和历史的插入、运行、删除交互已
  接通，但数据在重新打开抽屉后会重置。
- 每完成一个阶段，只做 `dart format`、`flutter analyze` 和用户明确要求的
  `flutter run`；不要自行运行复杂测试或管理模拟器。

## 1. 依赖与技术边界

按功能分批添加依赖，不要一次性引入全部包。添加前核对当前 pub.dev API 和
Android 支持情况。

- SSH/SFTP：`dartssh2`
- 终端模拟：`xterm`
- 普通数据：`sqflite`、`path`
- 密钥和 API Key：`flutter_secure_storage`
- 生物识别：`local_auth`
- Provider/Web Search HTTP 与流式响应：优先使用 `http` 的 streamed response
- Android 文件选择：优先评估 `file_picker` 的 SAF 上传和保存能力
- 稳定 ID：`uuid`

暂不添加全局状态管理框架。先使用 feature controller + `ChangeNotifier` /
`ListenableBuilder`，让 Widget 只渲染状态和派发意图；跨功能状态明显失控时再
评估 Riverpod。不得让 Widget 直接持有 `SSHClient`、shell 或 SFTP 句柄。

## 2. 基础目录与领域模型

- [x] 新建 `lib/core/storage/`：SQLite 打开、版本迁移和安全存储封装。
- [x] 新建 `lib/core/ssh/`：连接工厂、会话拥有者、主机密钥验证和错误映射。
- [x] 新建 `lib/core/terminal/`：xterm 适配器和终端输入事件定义。
- [ ] 各功能采用 `data/`、`application/`、`presentation/` 的最小必要分层；不要
  为单个类创建空目录或无意义接口。
- [x] 定义明确的连接状态：idle、connecting、awaitingHostTrust、authenticating、
  connected、reconnecting、disconnected、failed。
- [x] 定义可取消的 `SshSessionController`，统一拥有 socket、`SSHClient`、shell、
  SFTP 句柄和所有订阅；页面销毁或断开时从同一处释放。
- [x] 把基础设施异常转换为带阶段、主机和可展示消息的领域错误，不记录秘密。

建议 SQLite 首版表：

- `hosts`：id、name、host、port、username、auth_type、credential_ref、last_path、
  created_at、updated_at。
- `known_hosts`：host、port、algorithm、fingerprint、public_key、first_seen_at、
  last_seen_at；`host + port + algorithm` 唯一。
- `snippets`：id、name、command、description、tags_json、host_scope、pinned、
  created_at、updated_at。
- `command_history`：id、session_id、host_id、command、started_at、finished_at、
  exit_code、duration_ms、output_excerpt、pinned。
- `app_settings`：key、json_value、updated_at；普通偏好可放这里，秘密不能放。

安全存储键只保存 password、private key、passphrase、Provider API Key 和 Web
Search API Key。SQLite 仅保存不可逆引用 `credential_ref`，删除主机时同步删除
不再被引用的秘密。

## 3. 第一纵向切片：真实主机 CRUD

这是新会话应首先实现的切片。

- [x] 用强类型 `HostProfile`、`HostAuthType`、`HostRepository` 替换 `demoServer`
  和 `HomeShell._servers`。
- [x] 应用启动时异步加载主机；实现 loading、空列表和读取失败状态。
- [x] 完成新增/编辑表单：名称、主机、端口、用户名、密码或私钥认证。
- [x] 端口使用数值校验；主机、用户名和认证资料缺失时在字段旁显示错误。
- [x] 密码、私钥、passphrase 直接写安全存储，不经过 SQLite 或 debug log。
- [x] 主机列表点击仍进入终端连接流程；长按支持连接、编辑、复制地址和删除。
- [x] 删除前显示确认；删除失败时保持列表项并显示可重试错误。
- [x] Settings 中的主题和现有开关写入 SQLite，并在重启后恢复。

验收：杀掉并重开 App 后主机和设置仍存在；普通数据库中检索不到任何秘密明文。

## 4. 第二纵向切片：真实 SSH 连接

- [x] 使用 `dartssh2` 建立 TCP/SSH 连接，设置连接、认证和握手超时。
- [x] 支持密码和无口令/有口令私钥认证；keyboard-interactive 作为后续小切片。
- [x] 第一次遇到主机公钥时暂停连接，展示 host、port、算法和 SHA256 指纹。
- [x] 用户接受后写入 `known_hosts`；拒绝后立即断开，不创建 shell。
- [x] 已知主机密钥变化时必须阻断连接，不能提供“自动忽略”配置。
- [x] 把 DNS、超时、握手、主机密钥、认证和 shell 创建错误分别映射到 UI。
- [x] 连接页展示真实状态，连接失败可重试或返回。
- [x] Android 返回键按顺序处理键盘、菜单、抽屉、Agent 和断开确认。
- [x] 断开时取消流、关闭 shell、SFTP、SSHClient 和 socket，不留下假连接状态。

验收：可连接测试 Linux 主机；未知指纹只询问一次；篡改已保存指纹后连接被阻止；
错误密码不会进入终端。

## 5. 第三纵向切片：xterm 与远程 shell

- [x] 用 `xterm` 替换 `_TerminalLine`、隐藏 `TextField` 和 `_mockOutput`。
- [x] 根据终端列/行创建 PTY，并在尺寸变化或旋转时发送 resize。
- [x] shell stdout/stderr 以字节流进入终端；终端输入通过单一输入通道写入 shell。
- [x] 正确处理 UTF-8、中文宽字符、组合字符、ANSI 色彩和全屏程序。
- [x] 终端选区使用 xterm/Flutter 的原生选择、复制、全选和粘贴能力。
- [x] Termux 快捷键改为发送真实控制序列；Ctrl/Alt 为单次和锁定状态，方向键与
  PgUp/PgDn 支持长按重复，不能再修改隐藏文本框字符串。
- [x] 软键盘弹出后保持输入行可见；Agent 输入聚焦时快捷键不发送到远端。
- [x] 避免每个输出 chunk 重建整页；批量写终端 buffer，并独立更新连接状态。

验收：`vim`、`tmux`、`less`、`top`、Ctrl+C、Tab、方向键、中文输入、复制粘贴
和横竖屏 resize 均在用户模拟器或真机上验证。

## 6. 便签与历史持久化

- [ ] `SnippetRepository` 实现列表、搜索、新增、编辑、置顶、删除和设备范围。
- [ ] 便签“插入”只写终端输入；“运行”先确认，再发送完整命令。
- [ ] `HistoryRepository` 在用户实际发送命令时记录 host、时间和命令文本。
- [ ] 能可靠获取退出码时再写 exit_code；拿不到时保存 null，不能伪造成功。
- [ ] 输出摘要设置单条长度上限和全局清理策略，避免数据库无限增长。
- [ ] 历史支持按当前设备和关键词筛选、单条删除、清空、转为便签。
- [ ] 抽屉插入/运行后关闭并回到终端；删除后留在抽屉并即时更新列表。

## 7. SFTP 文件与传输

- [ ] 从 `SshSessionController` 获取共享 SSHClient，按需创建独立 SFTP 句柄。
- [ ] 文件抽屉实现加载、空目录、失败重试、返回上级、刷新和分页/数量说明。
- [ ] 支持目录进入、文件属性、文本预览、重命名、创建目录和删除确认。
- [ ] 上传使用 Android SAF 选文件；下载使用用户可见目录或创建文档流程。
- [ ] 传输任务有 queued、running、paused、completed、failed、cancelled 状态。
- [ ] 展示字节进度、速度、取消和重试；关闭抽屉不取消后台中的当前连接任务。
- [ ] 同名文件明确询问覆盖、跳过或重命名，不静默覆盖。

## 8. 服务器状态

- [ ] 建立按需 `ServerStatusService`，不做后台持续轮询。
- [ ] 针对 Linux 读取系统、CPU、内存、磁盘、负载和 uptime。
- [ ] 不同发行版字段缺失时逐项显示不可用，不能把整张状态卡判为成功或失败。
- [ ] 状态请求支持取消、超时和重试，关闭弹窗不影响终端 shell。

## 9. Agent Provider 与工具循环

### 9.1 Provider

- [ ] 定义统一 `AgentProvider`，输出 textDelta、status、toolCallDelta、toolResult、
  usage、completed、cancelled、error 事件。
- [ ] 实现 Messages 协议适配器和 Responses 协议适配器；都使用真正的流式响应。
- [ ] SSE/JSON 使用结构化解析器，不通过字符串切割猜事件字段。
- [ ] Provider 设置包括 endpoint、model、API Key、timeout、最大 loop 和默认选择。
- [ ] API Key 只从安全存储读取，不进入日志、SQLite、终端或模型上下文。

### 9.2 Read 工具

- [ ] `terminal_snapshot`：可见内容、有限 scrollback、当前输入和终端尺寸。
- [ ] `session_status`：连接状态、当前设备和非秘密会话信息。
- [ ] `history_query`：受数量和设备范围限制的命令历史。
- [ ] `sftp_list/stat/read_text`：只读目录、属性和受大小限制的文本文件。
- [ ] `server_status`：复用状态服务的只读快照。
- [ ] `web_search`：由应用注入结果，模型永远看不到搜索 API Key。

### 9.3 唯一 Write 工具

- [ ] 只提供 `request_commands`，参数包含一条或多条完整命令、原因和预期结果。
- [ ] 调用后进入 pendingApproval，完整展示目标设备和每条原始命令。
- [ ] 用户可逐条批准、整批批准、拒绝；编辑后的命令必须生成新的审批记录。
- [ ] 未批准前不能向 shell 写入任何字符；拒绝结果返回 Agent loop。
- [ ] 批准执行后采集受限输出并作为 tool result 回传，继续 loop。
- [ ] 每轮限制步数、总时长、上下文大小；用户停止后取消 HTTP stream 和工具任务。
- [ ] 只展示 Provider 明确允许的状态摘要，不展示私有思维链。

## 10. Agent 工作规范、搜索和生物锁

- [ ] Settings 支持全局 `AGENTS.md` 与单设备覆盖，明确合并优先级。
- [ ] 产品只读与审批规则是硬边界，用户规范不能覆盖。
- [ ] Web Search provider 独立配置 endpoint、API Key、超时和启用范围。
- [ ] 使用 `local_auth` 保护应用启动、查看私钥、查看 Provider Key 和打开 Agent。
- [ ] 处理无生物硬件、未录入、锁定、取消和系统错误，不用“验证成功”兜底。
- [ ] App 进入后台超过可配置时间后重新锁定秘密页面。

## 11. 生命周期与发布前清理

- [ ] 网络变化和应用恢复前台时检查真实 socket 状态，断线显示断开或显式重连。
- [ ] 首版不承诺后台保活；需要长期会话时另立前台服务任务并显示系统通知。
- [ ] 旋转和重建只恢复可恢复 UI 状态，不序列化 socket 或 SSHClient。
- [ ] 删除所有 `_mockOutput`、演示 Provider 回复、演示状态和硬编码服务器数据。
- [ ] 为第三方包补充许可证页面，确认 `example/` 不进入 APK 和发布源码依赖。
- [ ] 检查 release 日志、崩溃信息和数据库，确保没有密码、私钥、passphrase 或 Key。

## 12. 新会话的直接开工顺序

1. 阅读 `AGENTS.md`、`functional-spec.md` 和本文件。
2. 只实现第 2、3 节：SQLite/安全存储基础和真实主机 CRUD。
3. 用 repository/controller 替换 `HomeShell` 中的内存列表，不动已确认的视觉参数。
4. 完成 format/analyze 后，把主机新增、编辑、重启恢复和删除流程 run 到用户模拟器。
5. 用户确认后再进入第 4 节 SSH 连接，避免一次改动跨越持久化、网络和终端三层。

每个纵向切片结束时，更新本文件的勾选状态，并在交付中列出：已替换的 mock、
仍存在的 mock、静态检查结果，以及需要用户在 Android 上手测的确切流程。
