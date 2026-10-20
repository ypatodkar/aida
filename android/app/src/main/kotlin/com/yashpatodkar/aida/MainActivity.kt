package com.yashpatodkar.aida

import android.media.AudioAttributes
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var ringtone: Ringtone? = null
    private var ringback: ToneGenerator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var ringing = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aida/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        @Suppress("DEPRECATION")
                        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                        result.success(mapOf("name" to info.versionName, "code" to code))
                    }
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls())
                    "allowInstalls" -> {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    "install" -> {
                        try {
                            val file = File(call.argument<String>("path")!!)
                            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                            startActivity(Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install", "Android couldn't open the installer", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aida/call_audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "active" -> {
                        try {
                            val intent = Intent(this, CallForegroundService::class.java)
                                .putExtra("video", call.argument<Boolean>("video") == true)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("call_service", "Return to Aida to continue the call", null)
                        }
                    }
                    "endCall" -> {
                        stopService(Intent(this, CallForegroundService::class.java))
                        result.success(null)
                    }
                    "start" -> {
                        stopRinging()
                        ringing = true
                        if (call.argument<Boolean>("incoming") == true) {
                            val manager = getSystemService(AUDIO_SERVICE) as AudioManager
                            if (manager.ringerMode == AudioManager.RINGER_MODE_NORMAL) {
                                ringtone = RingtoneManager.getRingtone(this,
                                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
                                ringtone?.audioAttributes = AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build()
                                if (Build.VERSION.SDK_INT >= 28) ringtone?.isLooping = true
                                ringtone?.play()
                            }
                        } else {
                            ringback = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 65)
                            val pulse = object : Runnable {
                                override fun run() {
                                    if (!ringing) return
                                    ringback?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 1600)
                                    handler.postDelayed(this, 4000)
                                }
                            }
                            handler.post(pulse)
                        }
                        handler.postDelayed({ stopRinging() }, 60000)
                        result.success(null)
                    }
                    "stop" -> { stopRinging(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }
    private fun stopRinging() {
        ringing = false
        handler.removeCallbacksAndMessages(null)
        ringtone?.stop()
        ringtone = null
        ringback?.stopTone()
        ringback?.release()
        ringback = null
    }
    override fun onDestroy() { stopRinging(); super.onDestroy() }
}
