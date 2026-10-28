package com.komorebi.guitarbook

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var effects: EffectsChannel? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        effects = EffectsChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onResume() { super.onResume(); effects?.resume() }
    override fun onStop() { effects?.pause(); super.onStop() }
    override fun onDestroy() { effects?.destroy(); effects = null; super.onDestroy() }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == EffectsChannel.PERMISSION) effects?.permissionResult(
            grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED)
    }
}
