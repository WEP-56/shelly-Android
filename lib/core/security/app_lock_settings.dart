/// Everything the app lock can be asked to guard.
///
/// Every scope is opt-in on its own, so a user can protect the Agent panel
/// without unlocking on every launch, or the other way round.
enum AppLockScope {
  /// Cold start, and coming back from the background after the grace period.
  appStartup,

  /// Opening the Agent panel, which is the surface that can request commands.
  agentPanel,

  /// Opening the provider sheet, where a stored API key can be replaced.
  providerKey,

  /// Opening the credential editor of an already saved host.
  hostCredentials,
}

/// Every scope, in the order the settings sheet lists them.
const Set<AppLockScope> allAppLockScopes = {
  AppLockScope.appStartup,
  AppLockScope.agentPanel,
  AppLockScope.providerKey,
  AppLockScope.hostCredentials,
};

extension AppLockScopeInfo on AppLockScope {
  /// Persisted id. [Enum.name] is stable enough here because the values are
  /// only ever added to, never renamed.
  String get id => name;

  String get label => switch (this) {
    AppLockScope.appStartup => '打开应用',
    AppLockScope.agentPanel => '打开 Agent',
    AppLockScope.providerKey => '查看 Provider Key',
    AppLockScope.hostCredentials => '查看私钥',
  };

  String get description => switch (this) {
    AppLockScope.appStartup => '冷启动和后台超时返回时验证',
    AppLockScope.agentPanel => 'Agent 可以请求执行远程命令',
    AppLockScope.providerKey => '进入 Provider 配置前验证',
    AppLockScope.hostCredentials => '编辑已保存设备的认证资料前验证',
  };

  /// Reason handed to the system prompt, so the sheet says what is being
  /// unlocked instead of just "authenticate".
  String get authReason => switch (this) {
    AppLockScope.appStartup => '验证身份以解锁 Shelly',
    AppLockScope.agentPanel => '验证身份以打开 Agent',
    AppLockScope.providerKey => '验证身份以查看 Provider 配置',
    AppLockScope.hostCredentials => '验证身份以查看设备认证资料',
  };
}

AppLockScope? appLockScopeFromId(String id) {
  for (final scope in AppLockScope.values) {
    if (scope.id == id) return scope;
  }
  return null;
}

/// User-visible label for a re-lock delay.
String describeAppLockGrace(Duration grace) {
  if (grace <= Duration.zero) return '立即';
  if (grace.inMinutes < 1) return '${grace.inSeconds} 秒';
  return '${grace.inMinutes} 分钟';
}

/// Which surfaces the app lock guards and how long the app may sit in the
/// background before the unlock expires.
///
/// This is part of [AppSettings] and therefore lives in the ordinary settings
/// table: it holds no secret, only which screens ask for authentication.
class AppLockSettings {
  const AppLockSettings({
    this.enabled = false,
    this.scopes = allAppLockScopes,
    this.grace = defaultGrace,
  });

  final bool enabled;
  final Set<AppLockScope> scopes;

  /// How long the app may stay in the background before the current unlock is
  /// dropped. [Duration.zero] re-locks as soon as it is backgrounded.
  final Duration grace;

  static const defaultGrace = Duration(minutes: 1);

  /// Offered by the settings sheet; the persisted value is not restricted to
  /// this list, so an older or newer build's choice still round-trips.
  static const graceChoices = <Duration>[
    Duration.zero,
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  static const maxGrace = Duration(hours: 1);

  bool protects(AppLockScope scope) => enabled && scopes.contains(scope);

  bool get locksStartup => protects(AppLockScope.appStartup);

  /// True when the lock is on but guards nothing, which is worth warning about
  /// instead of silently doing nothing.
  bool get isIdle => enabled && scopes.isEmpty;

  AppLockSettings copyWith({
    bool? enabled,
    Set<AppLockScope>? scopes,
    Duration? grace,
  }) {
    return AppLockSettings(
      enabled: enabled ?? this.enabled,
      scopes: scopes ?? this.scopes,
      grace: grace ?? this.grace,
    );
  }

  AppLockSettings withScope(AppLockScope scope, bool value) {
    final next = Set<AppLockScope>.of(scopes);
    if (value) {
      next.add(scope);
    } else {
      next.remove(scope);
    }
    return copyWith(scopes: next);
  }

  /// Flat keys, spread into [AppSettings.toJson]. `biometric` keeps the name it
  /// was first persisted under.
  Map<String, Object> toJson() => {
    'biometric': enabled,
    'lockScopes': [for (final scope in scopes) scope.id],
    'lockGraceSeconds': grace.inSeconds,
  };

  factory AppLockSettings.fromJson(Map<String, Object?> json) {
    final rawScopes = json['lockScopes'];
    final scopes = <AppLockScope>{};
    if (rawScopes is List) {
      for (final entry in rawScopes) {
        final scope = entry is String ? appLockScopeFromId(entry) : null;
        if (scope != null) scopes.add(scope);
      }
    }
    final seconds = (json['lockGraceSeconds'] as num?)?.toInt();
    return AppLockSettings(
      enabled: json['biometric'] as bool? ?? false,
      scopes: rawScopes is List ? scopes : allAppLockScopes,
      grace: seconds == null
          ? defaultGrace
          : Duration(seconds: seconds.clamp(0, maxGrace.inSeconds)),
    );
  }
}
