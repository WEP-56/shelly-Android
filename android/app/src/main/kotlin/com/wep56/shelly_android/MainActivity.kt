package com.wep56.shelly_android

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity, not FlutterActivity: local_auth shows the
// androidx.biometric prompt as a fragment and requires a FragmentActivity host.
class MainActivity : FlutterFragmentActivity()
