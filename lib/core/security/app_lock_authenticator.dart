import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

/// Result of one authentication attempt.
///
/// There is deliberately no "assume success" branch: anything that is not a
/// confirmed pass is an [AppLockDenied] carrying a message the UI shows.
sealed class AppLockAuthResult {
  const AppLockAuthResult();
}

/// The user proved their identity.
class AppLockGranted extends AppLockAuthResult {
  const AppLockGranted();
}

/// The attempt did not pass, with the reason in [message].
class AppLockDenied extends AppLockAuthResult {
  const AppLockDenied(
    this.message, {
    this.canRetry = true,
    this.canDisable = false,
  });

  final String message;

  /// Whether trying again on this device can plausibly succeed.
  final bool canRetry;

  /// True when the device can never authenticate as configured (no hardware,
  /// nothing enrolled, no screen lock, plugin missing). The UI then offers to
  /// turn the app lock off instead of trapping the user out of their own data.
  final bool canDisable;
}

/// What the device can do, used by the settings UI before the lock is armed.
class AppLockAvailability {
  const AppLockAvailability({
    required this.canAuthenticate,
    required this.hasBiometricHardware,
    this.detail,
  });

  /// Biometrics or a device credential (PIN/pattern/password) can be used.
  final bool canAuthenticate;

  /// The device reports biometric hardware that this app may use.
  final bool hasBiometricHardware;

  /// Set when [canAuthenticate] is false, or when the probe itself failed.
  final String? detail;

  String get summary {
    if (!canAuthenticate) return detail ?? '设备不支持系统验证';
    if (hasBiometricHardware) return '可使用生物识别或设备密码验证';
    return '设备无可用生物识别，将使用设备密码验证';
  }
}

/// Thin wrapper over `local_auth`.
///
/// It owns two things the rest of the app should not repeat: the Android prompt
/// strings, and the mapping from [LocalAuthExceptionCode] to a message plus the
/// recovery options that code allows.
class AppLockAuthenticator {
  AppLockAuthenticator({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  static const _messages = <AuthMessages>[
    AndroidAuthMessages(
      signInTitle: 'Shelly 身份验证',
      signInHint: '验证后继续',
      cancelButton: '取消',
    ),
  ];

  /// Asks the platform what it supports. Never throws: a probe failure is
  /// reported as "cannot authenticate" with the reason attached, because the
  /// settings UI has to render something either way.
  Future<AppLockAvailability> probe() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        return const AppLockAvailability(
          canAuthenticate: false,
          hasBiometricHardware: false,
          detail: '设备未设置锁屏密码或生物识别，无法启用应用锁',
        );
      }
      final hasBiometrics = await _auth.canCheckBiometrics;
      return AppLockAvailability(
        canAuthenticate: true,
        hasBiometricHardware: hasBiometrics,
      );
    } on LocalAuthException catch (error) {
      return AppLockAvailability(
        canAuthenticate: false,
        hasBiometricHardware: false,
        detail: _describe(error).message,
      );
    } on MissingPluginException {
      return const AppLockAvailability(
        canAuthenticate: false,
        hasBiometricHardware: false,
        detail: '当前构建不包含系统验证插件',
      );
    } on PlatformException catch (error) {
      return AppLockAvailability(
        canAuthenticate: false,
        hasBiometricHardware: false,
        detail: '无法读取设备验证能力：${error.message ?? error.code}',
      );
    }
  }

  /// Runs one prompt. [reason] is shown by the system sheet, so it says what is
  /// being unlocked.
  Future<AppLockAuthResult> authenticate({required String reason}) async {
    try {
      final granted = await _auth.authenticate(
        localizedReason: reason,
        authMessages: _messages,
        // Device credential stays allowed: locking the app to biometrics only
        // would strand users whose sensor is unavailable.
        biometricOnly: false,
        // The prompt survives a backgrounding instead of failing outright,
        // which matters because the lock itself reacts to lifecycle changes.
        persistAcrossBackgrounding: true,
      );
      if (granted) return const AppLockGranted();
      // Android currently throws instead of returning false, but the platform
      // interface allows it for a plain failed challenge.
      return const AppLockDenied('验证未通过');
    } on LocalAuthException catch (error) {
      return _describe(error);
    } on MissingPluginException {
      return const AppLockDenied(
        '当前构建不包含系统验证插件，无法验证身份',
        canRetry: false,
        canDisable: true,
      );
    } on PlatformException catch (error) {
      return AppLockDenied('系统验证出错：${error.message ?? error.code}');
    }
  }

  /// Cancels a prompt that is still on screen. Returns whether the platform
  /// reported it stopped one.
  Future<bool> cancel() async {
    try {
      return await _auth.stopAuthentication();
    } on LocalAuthException {
      return false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The whole failure policy in one place.
  ///
  /// [LocalAuthExceptionCode] is documented as non-exhaustive, so `deviceError`,
  /// `unknownError` and any future code fall through to the last branch rather
  /// than being silently treated as success.
  static AppLockDenied _describe(LocalAuthException error) {
    final detail = error.description?.trim();
    final suffix = (detail == null || detail.isEmpty) ? '' : '：$detail';
    return switch (error.code) {
      LocalAuthExceptionCode.userCanceled => const AppLockDenied('验证已取消'),
      LocalAuthExceptionCode.systemCanceled => const AppLockDenied(
        '系统中断了验证，请重试',
      ),
      LocalAuthExceptionCode.timeout => const AppLockDenied('验证超时，请重试'),
      LocalAuthExceptionCode.authInProgress => const AppLockDenied(
        '已有一次验证正在进行，请先完成系统提示',
      ),
      LocalAuthExceptionCode.uiUnavailable => AppLockDenied(
        '暂时无法显示系统验证界面，请回到应用后重试$suffix',
      ),
      LocalAuthExceptionCode.userRequestedFallback => const AppLockDenied(
        '已切换到其他验证方式，请重试',
      ),
      LocalAuthExceptionCode.temporaryLockout => const AppLockDenied(
        '验证失败次数过多，请稍后重试',
      ),
      LocalAuthExceptionCode.biometricLockout => const AppLockDenied(
        '生物识别已被锁定，请先用设备密码解锁屏幕后重试',
      ),
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
        const AppLockDenied('生物识别硬件暂时不可用，请稍后重试'),
      LocalAuthExceptionCode.noBiometricsEnrolled => const AppLockDenied(
        '设备未录入指纹或人脸。请在系统设置中录入后重试，或关闭应用锁',
        canDisable: true,
      ),
      LocalAuthExceptionCode.noBiometricHardware => const AppLockDenied(
        '设备没有可用的生物识别硬件。请为设备设置锁屏密码，或关闭应用锁',
        canDisable: true,
      ),
      LocalAuthExceptionCode.noCredentialsSet => const AppLockDenied(
        '设备未设置锁屏密码或生物识别，无法完成验证。请在系统设置中添加，或关闭应用锁',
        canDisable: true,
      ),
      // deviceError, unknownError and codes added by a future plugin version.
      _ => AppLockDenied('身份验证未完成（${error.code.name}）$suffix'),
    };
  }
}
