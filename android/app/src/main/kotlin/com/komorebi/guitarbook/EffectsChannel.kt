package com.komorebi.guitarbook

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** All control operations and permission completions run on the main thread. */
class EffectsChannel(private val activity: MainActivity, messenger: BinaryMessenger) {
    companion object { const val PERMISSION = 9071; init { System.loadLibrary("guitarbook_mobile_effects") } }
    private val channel = MethodChannel(messenger, "guitarbook/effects")
    private val runningSessions = mutableSetOf<String>()
    private val engines = mutableMapOf<String, Long>()
    private var pending: Pair<MethodCall, MethodChannel.Result>? = null
    private var foreground = true
    private var destroyed = false
    private val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>) { interrupt() }
        override fun onAudioDevicesAdded(devices: Array<out AudioDeviceInfo>) { interrupt() }
    }
    private val focus = AudioManager.OnAudioFocusChangeListener { change ->
        if (change <= 0) interrupt()
    }
    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        manager.registerAudioDeviceCallback(devices, android.os.Handler(android.os.Looper.getMainLooper()))
    }
    private external fun nativeCreate(context: Context): Long
    private external fun nativeCommand(handle: Long, json: String): String
    private external fun nativeDispose(handle: Long)

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val session = call.argument<String>("session")
        if (session == null || destroyed) { result.error("closed", "效果器已关闭。", null); return }
        if (call.method == "dispose") {
            if (pending?.first?.argument<String>("session") == session) {
                pending?.second?.error("closed", "效果器已关闭。", null)
                pending = null
            }
            runningSessions.remove(session)
            engines.remove(session)?.let { nativeDispose(it) }
            releaseFocusIfIdle()
            result.success(null)
            return
        }
        if (call.method != "command") { result.notImplemented(); return }
        val command = call.argument<String>("command")
        if (command == "stop" && pending?.first?.argument<String>("session") == session) {
            pending?.second?.error("cancelled", "监听已取消，请手动重新开始。", null)
            pending = null
        }
        if (command == "start" || command == "probe") {
            if (!foreground) { result.error("background", "请回到前台后手动开始监听。", null); return }
            if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                if (pending != null) { result.error("permission", "请先完成录音授权。", null); return }
                pending = call to result
                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION)
                return
            }
            @Suppress("DEPRECATION")
            val granted = manager.requestAudioFocus(focus, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                result.error("audio_focus", "无法获得音频焦点，请结束其他通话或录音后重试。", null); return
            }
        }
        try {
            val engine = engines.getOrPut(session) { nativeCreate(activity.applicationContext) }
            val arguments = call.arguments as Map<*, *>
            val response = nativeCommand(engine, JSONObject(arguments).toString())
            val state = JSONObject(response).optJSONObject("result")
            if (state?.has("running") == true) {
                if (state.optBoolean("running")) runningSessions.add(session) else runningSessions.remove(session)
            } else if (command == "start" || command == "probe") runningSessions.remove(session)
            result.success(response)
        } catch (error: Exception) { result.error("effects", error.message, null) }
        releaseFocusIfIdle()
    }
    fun permissionResult(granted: Boolean) {
        val request = pending ?: return
        pending = null
        if (granted && foreground && !destroyed) handle(request.first, request.second)
        else request.second.error("permission", "未获得录音权限或应用已进入后台，请回到前台授权后重试。", null)
    }
    private fun releaseFocusIfIdle() {
        if (runningSessions.isEmpty()) {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(focus)
        }
    }
    fun interrupt() {
        runningSessions.clear()
        engines.values.forEach { nativeCommand(it, "{\"command\":\"stop\"}") }
        @Suppress("DEPRECATION")
        manager.abandonAudioFocus(focus)
    }
    fun pause() {
        foreground = false
        pending?.second?.error("background", "应用已进入后台，请回到前台后手动开始监听。", null)
        pending = null
        interrupt()
    }
    fun resume() { foreground = true }
    fun destroy() {
        destroyed = true
        pending?.second?.error("closed", "效果器已关闭。", null)
        pending = null
        interrupt()
        engines.values.forEach { nativeDispose(it) }
        engines.clear()
        manager.unregisterAudioDeviceCallback(devices)
        channel.setMethodCallHandler(null)
    }
}
