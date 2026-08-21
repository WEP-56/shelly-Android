# Shelly 下一阶段 TODO：连接稳定、后台增强、设置与功能补全

`docs/implementation-todo.md` 记录的是第 2–12 节已完成的历史，基本过时，只留作
存档；本文件是当前唯一的开工清单。

## 0. 本轮的工作方式

- 本轮几乎每一项都能在 `example/`（ServerBox）里找到已经跑通的做法，**先去看
  参考实现再动手，不要自己造轮子**。下面每条都给了 `example/` 的文件和行号。
- `example/` 是 AGPL：**只看思路和结构，不复制代码**，按 Shelly 现有的
  `feature/{domain,data,application,presentation}` + `ChangeNotifier` 架构重写；
  `example/` 不进入构建、不参与 `flutter analyze`。
- 安全硬边界不变：密码/私钥/passphrase/API Key 只进安全存储；host key 校验不可
  关闭；Agent 写操作必须先审批；不得用 `catch (_)` 吞错或伪造成功。
- 每完成一项只做 `dart format` 和 `flutter analyze`；真机验证由用户执行，代理不
  得声称自己验证过终端/后台/通知/生物识别流程。
- 依赖按需分批加：`wakelock_plus`（后台增强）、`flutter_local_notifications`
  或纯原生前台服务（二选一，见第 2 节）。其余尽量不加新包。

## 1. 连接稳定（最高优先级）

用户现象：**打开侧边栏操作一会儿，SSH 就断开**。下面前四项是已经在代码里核实过
的成因或放大器，不是猜测。

### 1.1 dartssh2 的 keepalive 检测不到断线

- 现状：`lib/core/ssh/ssh_connection_factory.dart:286` 传
  `keepAliveInterval: 15s`，但 dartssh2 3.3.0 的 `SSHKeepAlive`
  （`lib/src/ssh_keepalive.dart`）用 `catch (_)` 吞掉全部异常，且
  `SSHClient.ping()` → `_sendGlobalRequest`（`lib/src/ssh_client.dart:763`、
  `843-850`）**等回包时没有超时**。只要有一次回包没回来，`_isPinging` 永远为
  `true`，之后再也不会发 ping。也就是说这个 keepalive 只制造流量，永远不会报告
  连接已死。
- [x] 在应用层自己做健康检查：`Timer.periodic` 调 `ping().timeout(...)`，连续失
      败到阈值才判定掉线；恢复前台、抽屉可见性变化时立刻补一次检查。
      → `lib/core/ssh/ssh_health_monitor.dart`（30s 周期 / 10s 超时 / 连续 3 次；
      前台恢复与抽屉关闭走 `check(immediate: true)`，阈值降为 2 并带一次 3s 补测），
      工厂不再传 `keepAliveInterval`，心跳与检测统一由本监视器负责。
- [x] 参考 `example/lib/view/page/ssh/page/init.dart:209-270`
      （`_setupDiscontinuityTimer` / `_checkConnectionHealth` /
      `_handleConnectionCheckFailure`）和 `page.dart:183-185`
      （`_connectionCheckInterval = 60s`、`_connectionCheckTimeout = 10s`、
      `_maxKeepAliveFailures = 3`）、`page.dart:304-330`（resume 时
      `_checkConnectionHealth(immediate: true)`）、`page.dart:713-733`
      （可见性变化时补检查）。
- [x] 检查中要有 `_isCheckingConnection` 之类的重入保护，避免检查本身堆积。
      → `SshHealthMonitor._checking` + `_pendingImmediate`，并用 `_epoch` 让
      `stop()` 之后返回的在途探测失效。

### 1.2 `自动重连` 是个死开关

- 现状：`AppSettings.autoReconnect`（`lib/app/models.dart:90`）在设置页有开关
  （`lib/features/settings/settings_view.dart:143-147`），但**全项目没有任何消费
  者**；`SshConnectionState.reconnecting` 只在用户手动点重试时出现
  （`lib/core/ssh/ssh_session_controller.dart:52`、`59`、`70`）。断线后没有任何
  自动恢复。
- [x] 让开关真正生效：判定掉线后按退避重连（首次 1s，最多 3–5 次，指数退避），
      重连期间保持 `reconnecting` 状态和终端内容，不清屏。
      → `SshSessionController._scheduleReconnect`（1s→2s→4s→8s，最多 4 次），
      重连过程只往输出流写一行 `[Shelly] …` 提示，清屏只保留给手动"重试"。
- [x] 复用已有的退避实现思路 `lib/features/agent/provider/agent_retry.dart`（已带
      抖动），不要另写一份。
      → 抽到 `lib/core/retry/backoff_policy.dart`，`AgentRetryPolicy` 改为继承它，
      core 不反向依赖 features。
- [x] 重连必须复用原 `HostProfile` 与已信任的 host key；指纹变化时照旧阻断，不因
      为"自动重连"放宽校验。
      → 重连走同一个 `_factory.connect(profile: _host, promptForHostTrust: …)`；
      `_canAutoReconnect` 明确排除 `credential`/`hostKey`/`authentication` 阶段。
- [x] 重连失败后落到明确的 `failed` 状态并给出原因，不允许静默停在 loading。
      → `_enterFailed` 在次数耗尽时改写文案为"已尝试自动重连 N 次仍未成功…"。

### 1.3 一次 resize / 一次写入失败就杀掉整个会话

- 现状：`lib/core/ssh/ssh_session_controller.dart:157-175` 里 `resizeTerminal` 失
  败直接 `_failSession('调整远程终端尺寸失败。')`；`sendInput`
  （`:140-154`）失败时 `++_generation` + `_cleanupConnection()` + `failed`。抽屉
  开合、软键盘弹出、旋转都会触发 resize，任何一次抖动都会被升级成"断开"。
- [x] resize 失败改为可恢复：记录一次警告、保留期望尺寸、下次成功时补发，不改连
      接状态。
      → `_flushTerminalSize`：`_resizePending` 记住期望尺寸，`_resizeWarned` 保证
      只警告一次，补发成功再记一条"尺寸已补发成功"。
- [x] 只有传输层真的关闭（`connection.done` / socket 错误）才允许进入 `failed`。
      → 写入失败只警告 + 触发一次即时健康检查后 `rethrow`；`failed` 只由
      `_handleLinkLoss`（`done` 的 onError / 流 onError / 心跳判死）进入。
- [x] 区分"远端主动关闭"（正常退出，`_handleRemoteClose`）与"链路异常"
      （`_handleRemoteError`），UI 文案和是否自动重连要不同。
      → 正常关闭记"远端已正常关闭会话"并停在 `disconnected`、不重连（不跟用户的
      `exit` 打架）；链路异常记"SSH 链路异常，连接已中断。"并进入自动重连。

### 1.4 侧边栏每次打开都新建 SFTP 通道，且关闭不等待

- 现状：`lib/features/sftp/sftp_drawer.dart:137-158` 每次打开抽屉都 new 一个
  `SftpBrowserController`；它在 `dispose()` 里
  `unawaited(_sftp?.close())`（`lib/features/sftp/sftp_browser_controller.dart:185-192`）
  ——不等待、异常无人观察，然后立刻把 `_sftp` 置空。每个传输任务又会另开一个
  SFTP 会话（`lib/features/sftp/sftp_transfer_controller.dart:217`）。
  OpenSSH 默认 `MaxSessions 10`，反复开合抽屉 + 并发传输很容易把通道打满，而
  `dartssh2` 的 `SftpClient.close()` 会用 `SftpAbortError` 打断所有在途请求
  （`lib/src/sftp/sftp_client.dart:261-266`）。
- [x] 让一个 SSH 会话只维护**一个**浏览用 SFTP 通道，由 `SshSessionController`
      持有并复用，抽屉关闭只丢弃 UI 状态、不关通道。
      → `openBrowseSftpSession()`（含在途去重），`SftpBrowserController.dispose()`
      只把引用置空。
- [x] 传输任务的通道数量设上限（复用现有 `maxConcurrent = 2`），并在任务结束后
      `await` 关闭、带超时，失败要记录而不是 `unawaited` 丢掉。
      → `SftpTransferController._run` 的 `finally` 改为
      `await _sshSession.closeSftpSession(session)`，关闭超时 5s 并记录失败。
- [x] 加一个当前打开通道数的内部计数，超过阈值时拒绝新开并给出可读错误，而不是
      让服务器来拒绝。
      → `maxSftpChannels = 5`（浏览 1 + 传输 2 + Agent 1 + 1 备用，远低于
      `MaxSessions 10`），超限抛"SFTP 通道数量已达上限…"。
- [x] 参考 `example/lib/core/utils/sftp_file_backend.dart` 和
      `example/lib/core/utils/sftp_timeout.dart` 的通道复用与超时处理。
      → 采纳其"调用方持有 SSH 连接、通道自己持有并负责关闭"的分工，并给开通道加了
      15s 超时；超时后仍然把迟到打开的通道关掉，不让它白占服务器会话数。

### 1.5 断开没有任何可观测性

- 现状：断开时只有一句 `SSH 会话意外断开，请重试连接。`，没有记录阶段、原因类
  型、发生时刻，用户和开发都无法判断到底是哪一类断开。
- [x] 在 `SshSessionController` 里维护一个有上限的连接事件环形缓冲（状态迁移、
      失败阶段、异常类名、时间戳），**不记录任何秘密和命令内容**。
      → `lib/core/ssh/ssh_connection_event.dart`（上限 80 条，只存
      `error.runtimeType`，不存异常消息）。
- [x] 终端状态弹窗里加"连接诊断"入口展示这些事件，方便用户直接反馈。
      → `lib/features/terminal/connection_diagnostics_sheet.dart`；入口在服务器状态
      弹窗底部（加载失败时也可点），断开/失败遮罩上也有一个，支持一键复制。
- [x] 关键失败用 `debugPrint` 之外的统一日志出口，参考
      `example/lib/view/page/ssh/page/init.dart:256` 的
      `Loggers.root.warning('SSH keep-alive failed', ...)` 分级方式。
      → `lib/core/diagnostics/app_log.dart`（debug/info/warning/error 四级、上限
      200 条环形缓冲，仅 debug 构建额外 `debugPrint`）。

### 1.6 屏幕熄灭 / 进入后台就被系统掐断

- 现状：Shelly 没有任何 wakelock，也没有会话级别的生命周期处理（只有
  `AppLockController.didChangeAppLifecycleState`）。屏幕一灭 Dart Timer 停摆，
  keepalive 不再发，服务器 `ClientAliveCountMax` 到点就断。
- [x] 加 `wakelock_plus`，终端页在前台且设置开启时持有，页面销毁时释放。参考
      `example/lib/view/page/ssh/page/page.dart:849`（按 `sshWakeLock` 决定）、
      `:283`（`_sshConnCount == 1` 时 enable）、`:240`（计数归零时 disable）。
      → `wakelock_plus: ^1.5.2` + `lib/core/system/wakelock_coordinator.dart`
      （按持有者引用计数，全局开关与终端页各持一个 token，互不误伤）；终端页在
      `resumed` 之外的生命周期也会释放，避免在别的应用前台顶着屏幕。
- [x] 设置里给出"终端保持屏幕常亮"开关（对齐 `sshWakeLock`，默认开）与"全局常
      亮"（对齐 `generalWakeLock`，默认关）。
      → `AppSettings.terminalWakeLock = true` / `globalWakeLock = false`，设置页
      "连接"分组下两个开关；全局项由 `ShellyApp` 持有。
- [x] 真正的后台存活见第 2 节，本项只解决"亮屏但息屏"的场景。
      （`wakelock_plus` 在 Android 上只是 `FLAG_KEEP_SCREEN_ON`，无需 `WAKE_LOCK`
      权限，manifest 不用改。）

### 1.7 验收

- 反复开合文件抽屉 20 次、期间上传下载各一次，SSH 不断；抽屉关闭后终端仍可输入。
- 拔掉 Wi-Fi 10 秒再插回，应看到 `正在重连` 并自动恢复；持续断网则落到明确失败。
- 息屏 5 分钟后回到应用，连接仍在或给出真实的重连过程，不出现"看起来连着但输入
  没反应"的假连接。

## 2. 后台增强

`docs/implementation-todo.md` 第 11 节写的"首版不承诺后台保活"由本节取代。整套做
法在 `example/` 里是完整的，直接照抄结构（不抄代码）。

### 2.1 Android 前台服务

- [ ] 新建前台服务，`foregroundServiceType="dataSync"`，常驻通知展示当前会话数、
      名称、连接状态和计时；带"全部断开"动作。参考
      `example/android/app/src/main/kotlin/tech/lolli/toolbox/ForegroundService.kt`
      （通知渠道、`ensureForeground`、`createMergedNotification` 的
      `setOngoing`/`setOnlyAlertOnce`/`setUsesChronometer`、InboxStyle 多会话折
      叠、`ACTION_STOP_FOREGROUND` 广播回 Flutter 断开全部连接）。
- [ ] manifest 补 `FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、
      `POST_NOTIFICATIONS`，并声明 `<service android:exported="false" ... />`。
      参考 `example/android/app/src/main/AndroidManifest.xml:8-11`、`:77-81`。
- [ ] Android 13+ 必须在 `startForeground` 之前检查 `POST_NOTIFICATIONS`；被拒绝
      时**优雅退化**（`stopSelf`，记录一个"无通知权限"标记，UI 明确告知后台保活
      不可用），不能崩、也不能假装开启成功。参考 `ForegroundService.kt` 的
      `onStartCommand` / `ensureForeground` 权限分支，和
      `example/lib/data/store/setting.dart:409` 的 `noNotiPerm`。

### 2.2 会话注册表与方法通道

- [ ] 建一个全局会话注册表（id、名称、`user@host:port`、开始时间、状态），会话增
      删时同步给原生：为空则停服务，非空则启动并刷新通知。参考
      `example/lib/data/ssh/session_manager.dart`（`TermSessionInfo` /
      `TermSessionManager._sync()`）。
- [ ] 方法通道约定：Flutter→原生 `startService` / `stopService` /
      `updateSessions(payload)` / `isServiceRunning`；原生→Flutter
      `disconnectSession{id}` / `stopAllConnections`。参考
      `example/lib/core/chan.dart:26-34`、`:80-100`、`:120-145`。
- [ ] 通知里的会话标题只放主机名和 `user@host:port`，**不放命令、路径或任何秘
      密**——通知内容会出现在锁屏上。
- [ ] 设置里给"后台保持连接"开关，默认关（对齐
      `example/lib/data/store/setting.dart:403` 的 `fgService`），关闭时完全不启动
      服务、不申请通知权限。

### 2.3 应用生命周期与会话托管

- [ ] 终端页监听 `didChangeAppLifecycleState`：`resumed` 时立刻补一次健康检查并
      恢复焦点；`paused` 时标记会话无 UI，但（在开关打开时）不关闭连接。参考
      `example/lib/view/page/ssh/page/page.dart:304-330`。
- [ ] 离开终端页时，连接是否保留由"后台保持连接"开关决定；不保留就按现有路径完
      整释放（socket/shell/SFTP/订阅一处释放）。
- [ ] 后台被系统杀死后重启，注册表要能自愈：残留通知必须清掉，不能留下指向已死
      会话的常驻通知。

### 2.4 tmux 续接（后台存活的真正解法，可选但强烈建议）

- [ ] 连接时可选自动 attach tmux 会话；断线重连后重新 attach 同一 session/window，
      终端内容由远端恢复，App 被杀也不丢工作。参考
      `example/lib/data/ssh/tmux/`（`tmux_command_builder.dart`、
      `tmux_session_scanner.dart`、`tmux_restore_state.dart`、
      `tmux_launch_plan.dart`）和
      `example/lib/view/page/ssh/page/init.dart:280-314`
      （`_onConnectionLossSuspected` → `_tryReconnectTmux` → 失败才弹断开对话框）。
- [ ] 设置三项对齐 `example/lib/data/store/setting.dart:460-466`：`tmuxAuto`（自动
      attach）、`tmuxShowSelector`（多会话时让用户选）、`tmuxSessionName`（默认会
      话名）。
- [ ] 远端没有 tmux 时明确提示并退回普通 shell，不静默失败。

### 2.5 验收

- 开启"后台保持连接"，回到桌面 10 分钟，通知一直在且计时正确，回到应用后终端可
  直接输入。
- 通知"全部断开"能真的断开所有会话并移除通知。
- 关闭开关后，回桌面即断开、无常驻通知、不申请通知权限。
- 拒绝通知权限时有明确提示，应用不崩、开关不显示为已生效。

## 3. 设置与功能补全（对照 `example/` 调研）

### 3.1 先清理假开关和假数据（必做）

以下都是"UI 有、行为无"，属于 demo 残留，必须要么接上要么删掉：

- [ ] `压缩传输 / gzip 通道`（`lib/features/settings/settings_view.dart:152-157`）：
      dartssh2 3.3.0 的协商里压缩算法只有 `none`
      （`lib/src/ssh_transport.dart:1317-1318`），这个开关**永远不可能生效，直接
      删除**。
- [ ] `自动重连`：按 1.2 接上真实行为。
- [ ] `终端响铃`（`settings_view.dart:173`）：接到 xterm 的 bell 回调，或删除。
- [ ] `长按震动`（`settings_view.dart:215`）：目前 `HapticFeedback` 是无条件调用
      的（例如 `lib/features/servers/server_list_view.dart:75`），需要让开关真正
      控制，或删除。
- [ ] `SSH 密钥`（`settings_view.dart:160-171`）：现在是硬编码的
      `id_ed25519` / `SHA256:nR1k+8f2aQ9Lm` 假数据，必须替换为真实私钥管理页
      （见 3.3）或删除该行。
- [ ] `开源许可`行：接 `showLicensePage` 或删除。

### 3.2 缺失的设置项（按价值排序）

对照 `example/lib/data/store/setting.dart`：

- [ ] 连接超时与最大重试次数可配（`timeout` 默认 5、`maxRetryCount` 默认 2，
      `:24`、`:49`）；现在 Shelly 的超时全是
      `lib/core/ssh/ssh_connection_factory.dart` 里的硬编码常量。
- [ ] 终端字体族/字体文件与字号（`fontPath`、`termFontSize`，`:55`、`:78`）；
      Shelly 只有字号。
- [ ] 终端配色主题（`termTheme`，`:322`），至少给亮/暗两套预设。
- [ ] SFTP 行为：打开上次路径、文件夹优先、显示隐藏文件、删除目录是否用 `rm -r`
      （`sftpOpenLastPath`、`sftpShowFoldersFirst`、`showHiddenFiles`、
      `sftpRmrDir`，`:211`、`:214`、`:224`、`:192`）。
- [ ] 是否记录命令历史的总开关（`recordHistory`，`:27`）。
- [ ] 虚拟键：Ctrl/Alt 用后自动复位（`sshVirtualKeyAutoOff`，`:84`）、横向排列
      （`horizonVirtKey`，`:346`）。
- [ ] 主题色种子 / 跟随系统取色（`colorSeed`、`useSystemPrimaryColor`，`:41`、
      `:195`）与全局字号缩放（`textFactor`，`:38`）。
- [ ] 启动时自动检查更新开关（`autoCheckAppUpdate`，`:176`）——更新检查已实现，缺
      的只是这个开关，且必须保持"不静默轮询"的既有约束。
- [ ] 终端背景图与透明度/模糊（`sshBgImage`、`sshBgOpacity`、`sshBlurRadius`，
      `:353-355`）——低优先级，视觉项。

### 3.3 缺失的功能（按价值排序）

- [ ] **私钥管理页**：独立的私钥库（新增/导入/命名/删除），主机编辑时从库里选而
      不是每台机粘贴一遍私钥。参考
      `example/lib/view/page/private_key/{list,edit}.dart` 和
      `example/lib/data/model/server/private_key_info.dart`。私钥正文仍然只进安全
      存储，SQLite 只存不可逆引用；查看私钥沿用已有的应用锁入口。
- [ ] **跳板机（Jump Host）**：主机可配置一到多个跳板，按链路依次建立。参考
      `example/lib/data/model/server/ssh_credential.dart:45-98`
      （`jumpId`/`jumpIds`/`resolvedJumpIds`）和
      `example/lib/core/utils/jump_chain.dart`（必须做环检测，否则会无限递归）。
- [ ] **多会话标签**：同时保持多台设备的终端并切换。参考
      `example/lib/view/page/ssh/{tab,tab_add,tab_sort}.dart`。这一项和第 2 节的会
      话注册表天然配套，建议放在后台增强之后做。
- [ ] **端口转发**：本地/远程转发的增删与状态展示。参考
      `example/lib/view/page/port_forward.dart` 和
      `example/lib/data/model/server/port_forward.dart`。
- [ ] **远程文本编辑**：SFTP 现在只有只读预览，补成可编辑保存（带语法高亮、软换
      行、保存后可选关闭）。参考 `example/lib/view/page/setting/entries/editor.dart`
      与 `editorTheme`/`editorHighlight`/`editorSoftWrap`/`closeAfterSave`
      （`setting.dart:108`、`:208`、`:342`、`:406`）。
- [ ] **导入 `~/.ssh/config`**：从文本导入主机列表。参考
      `example/lib/core/utils/ssh_config.dart`。Android 上没有 `~/.ssh`，入口应是
      "选择配置文件/粘贴文本"。
- [ ] **SFTP sudo 提权**：无权限目录下的读写。参考
      `example/lib/core/utils/{sftp_sudo,sftp_escalation}.dart`。sudo 密码属于秘
      密，必须走安全存储且不进日志。
- [ ] **主机标签与排序、自动连接、每主机环境变量**：参考 `Spi` 的
      `tags`/`autoConnect`/`envs`/`customSystemType`
      （`example/lib/data/model/server/server_private_info.freezed.dart:27-29`）。
- [ ] **本地文件浏览与"分享到"**：上传时可从应用内浏览本地文件、以及从其他应用
      分享文件进来上传。参考 `example/lib/view/page/storage/{local,send_to}.dart`。
- [ ] **局域网设备发现**（可选）：参考
      `example/lib/core/service/ssh_discovery.dart`。
- [ ] **ProxyCommand**（可选，Android 上受限）：参考
      `example/lib/core/utils/proxy_command_socket.dart`；它依赖本地进程执行，
      Android 上大概率做不到，评估后要么明确不做、要么只支持有限形式。

## 4. 建议开工顺序

1. 第 1 节全部（1.1 → 1.2 → 1.3 → 1.4 → 1.5 → 1.6），这是用户当前最痛的问题，
   且 1.5 的可观测性会让后面的判断有依据。
2. 第 3.1 节清理假开关（工作量小，直接消除"设置里有但没用"的困惑）。
3. 第 2 节后台增强（2.1 → 2.2 → 2.3），完成后再评估 2.4 tmux。
4. 第 3.2 节设置补全，再按 3.3 的顺序挑功能做，每次一个纵向切片。

每完成一节：更新本文件勾选状态、更新 `docs/handoff.md`，并在交付里列出改了哪些
文件、`flutter analyze` 结果，以及需要用户在 Android 真机上手测的确切步骤。
