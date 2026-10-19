package com.yashpatodkar.aida

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class CallForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channel = "aida_ongoing_call_v2"
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(channel, "Ongoing calls", NotificationManager.IMPORTANCE_LOW))
        }
        val launch = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
        val notification = builder.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Aida call in progress").setContentText("Tap to return to your call")
            .setOngoing(true).setCategory(Notification.CATEGORY_CALL).setContentIntent(launch).build()
        var types = 0
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (intent?.getBooleanExtra("video", false) == true &&
            checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (types == 0) { stopSelf(); return START_NOT_STICKY }
        if (Build.VERSION.SDK_INT >= 29) startForeground(7001, notification, types)
        else startForeground(7001, notification)
        return START_NOT_STICKY
    }
}
