import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';

const _storage = FlutterSecureStorage();
final _notices = FlutterLocalNotificationsPlugin();
const _defaultApi = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://44.209.97.214',
);

int noticeId(String value) =>
    value.codeUnits.fold(7, (h, c) => ((h * 31) + c) & 0x7fffffff);
int topicNoticeId(String pair, String topic) =>
    noticeId('message:$pair:$topic');

@pragma('vm:entry-point')
Future<void> firebaseBackground(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp();
  await initializeLocalNotifications();
  await showRemoteEvent(message.data);
}

@pragma('vm:entry-point')
void notificationBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await initializeLocalNotifications();
  await performNotificationAction(response);
}

Future<void> initializeLocalNotifications({
  void Function(NotificationResponse)? onTap,
}) => _notices.initialize(
  settings: const InitializationSettings(
    android: AndroidInitializationSettings('ic_notification'),
  ),
  onDidReceiveNotificationResponse: onTap,
  onDidReceiveBackgroundNotificationResponse: notificationBackground,
);

Future<AidaApi?> _savedApi() async {
  final token = await _storage.read(key: 'session_token');
  if (token == null) return null;
  return AidaApi(
    await _storage.read(key: 'api_url') ?? _defaultApi,
    token: token,
  );
}

Future<void> performNotificationAction(NotificationResponse response) async {
  if (!['reply', 'retry', 'decline'].contains(response.actionId)) return;
  final data = jsonDecode(response.payload ?? '{}') as Map<String, dynamic>;
  final api = await _savedApi();
  if (api == null) return;
  final id = response.id ?? 0;
  final text = (response.input ?? data['draft'] ?? '').toString().trim();
  final replyId = data['replyId']?.toString() ?? const Uuid().v4();
  try {
    final state = await api.me();
    if ((state['pair'] as Map?)?['id'] != data['pairId']) {
      await _notices.cancel(id: id);
      return;
    }
    if (response.actionId == 'decline') {
      await api.callAction(data['callId'] as String, 'decline');
      await _notices.cancel(id: id);
    } else if (text.isNotEmpty) {
      await api.sendMessage(
        text,
        replyId,
        topicId: data['topicId'] as String,
        pairId: data['pairId'] as String,
      );
      await _notices.show(
        id: id,
        title: 'Reply sent',
        body: text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'aida_updates_v2',
            'Quiet updates',
            importance: Importance.low,
            playSound: false,
            enableVibration: false,
            onlyAlertOnce: true,
            visibility: NotificationVisibility.private,
          ),
        ),
        payload: jsonEncode(
          data
            ..remove('draft')
            ..remove('replyId'),
        ),
      );
    }
  } catch (_) {
    if (response.actionId == 'decline') {
      await _notices.cancel(id: id);
    } else {
      await _notices.show(
        id: id,
        title: 'Reply not sent',
        body: 'Tap Retry, or open Aida. Your reply is saved here.',
        payload: jsonEncode({...data, 'draft': text, 'replyId': replyId}),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'aida_messages_v2',
            'Messages',
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.private,
            actions: [
              AndroidNotificationAction(
                'retry',
                'Retry',
                cancelNotification: false,
              ),
            ],
          ),
        ),
      );
    }
  } finally {
    api.close();
  }
}

Future<void> showRemoteEvent(Map<String, dynamic> data) async {
  final api = await _savedApi();
  if (api == null) return;
  try {
    final state = await api.me();
    final pair = state['pair'] as Map<String, dynamic>?;
    if (data['type'] == 'disconnected') {
      if (pair == null) await _notices.cancelAll();
      return;
    }
    if (pair?['id'] != data['pairId']) return;
    if (data['type'] == 'message') {
      final item = await api.message(data['messageId'].toString());
      if (item['senderId'] == (state['user'] as Map)['id']) return;
      final topicId = item['topicId'] as String;
      final seenKey = 'notice_${data['pairId']}_$topicId';
      final last = int.tryParse(await _storage.read(key: seenKey) ?? '') ?? 0;
      if ((item['id'] as int) <= last) return;
      final preview = item['kind'] == 'text'
          ? item['text'] as String
          : item['kind'] == 'image'
          ? 'Sent a photo'
          : 'Sent a video';
      final payload = jsonEncode({
        'type': 'message',
        'pairId': data['pairId'],
        'topicId': topicId,
      });
      await _notices.show(
        id: topicNoticeId(data['pairId'] as String, topicId),
        title: '${item['senderName']} · ${item['topicName']}',
        body: preview,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'aida_messages_v2',
            'Messages',
            importance: Importance.high,
            priority: Priority.high,
            color: const Color(0xFF234C43),
            visibility: NotificationVisibility.private,
            category: AndroidNotificationCategory.message,
            styleInformation: BigTextStyleInformation(preview),
            actions: const [
              AndroidNotificationAction(
                'reply',
                'Reply',
                semanticAction: SemanticAction.reply,
                cancelNotification: false,
                inputs: [AndroidNotificationActionInput(label: 'Your reply')],
              ),
            ],
          ),
        ),
      );
      await _storage.write(key: seenKey, value: item['id'].toString());
    } else if (data['type'] == 'call' || data['type'] == 'call_changed') {
      final current =
          (await api.currentCall())['call'] as Map<String, dynamic>?;
      final id = noticeId('call:${data['callId']}');
      if (current == null ||
          current['id'] != data['callId'] ||
          current['state'] != 'ringing' ||
          current['initiatorId'] == (state['user'] as Map)['id']) {
        await _notices.cancel(id: id);
        return;
      }
      final remaining =
          60000 -
          (DateTime.now().millisecondsSinceEpoch -
              (current['createdAt'] as int));
      if (remaining <= 0) return;
      final name = (pair!['partner'] as Map)['name'] as String;
      await _notices.show(
        id: id,
        title: name,
        body: 'Incoming ${current['kind']} call',
        payload: jsonEncode({...data, 'type': 'call'}),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'aida_calls_v2',
            'Incoming calls',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call,
            ongoing: true,
            autoCancel: false,
            visibility: NotificationVisibility.private,
            timeoutAfter: remaining,
            sound: const UriAndroidNotificationSound(
              'content://settings/system/ringtone',
            ),
            audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
            additionalFlags: Int32List.fromList([4]),
            actions: const [
              AndroidNotificationAction('decline', 'Decline'),
              AndroidNotificationAction(
                'answer',
                'Answer',
                showsUserInterface: true,
              ),
            ],
          ),
        ),
      );
    }
  } catch (_) {
    // Never show stale content when authorization or pairing can no longer be verified.
  } finally {
    api.close();
  }
}

class AidaNotifications {
  bool firebaseReady = false;
  bool serverReady = false;
  bool permissionGranted = false;
  StreamSubscription? _tokenChanges;
  StreamSubscription? _messages;
  NotificationResponse? pending;
  void Function(NotificationResponse)? onTap;
  Future<void> initialize() async {
    await initializeLocalNotifications(
      onTap: (response) {
        pending = response;
        onTap?.call(response);
      },
    );
    pending = (await _notices.getNotificationAppLaunchDetails())
        ?.notificationResponse;
    try {
      await Firebase.initializeApp();
      firebaseReady = true;
      FirebaseMessaging.onBackgroundMessage(firebaseBackground);
      _messages = FirebaseMessaging.onMessage.listen((event) {
        if (event.data['type'] == 'message') {
          unawaited(showRemoteEvent(event.data));
        }
      });
    } catch (_) {
      firebaseReady = false;
    }
  }

  Future<void> register(AidaApi api) async {
    permissionGranted =
        await _notices
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission() ??
        true;
    if (!firebaseReady) return;
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      serverReady = (await api.registerDevice(token))['enabled'] == true;
    }
    await _tokenChanges?.cancel();
    _tokenChanges = FirebaseMessaging.instance.onTokenRefresh.listen((
      token,
    ) async {
      if (api.token != null) {
        try {
          serverReady = (await api.registerDevice(token))['enabled'] == true;
        } catch (_) {}
      }
    });
  }

  Future<void> clear() => _notices.cancelAll();
  Future<void> cancelCall(String id) =>
      _notices.cancel(id: noticeId('call:$id'));
  Future<void> cancelTopic(String pair, String topic) =>
      _notices.cancel(id: topicNoticeId(pair, topic));
  void dispose() {
    _tokenChanges?.cancel();
    _messages?.cancel();
  }
}
