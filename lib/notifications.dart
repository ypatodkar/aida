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

/// Whether a message event from the live socket should raise a system
/// notification. Never for the conversation on screen; and while backgrounded,
/// only when push is unavailable, because Firebase then delivers it and two
/// paths would alert twice.
bool socketShouldNotify({
  required bool foreground,
  required bool conversationVisible,
  required bool pushActive,
}) => !conversationVisible && (foreground || !pushActive);

/// Whether a push that arrives while Aida is open should raise a notification.
/// The live socket normally handles foreground messages; push only covers the
/// moments it is reconnecting.
bool foregroundPushShouldNotify({
  required bool liveConnected,
  required bool conversationVisible,
}) => !liveConnected && !conversationVisible;

int noticeId(String value) =>
    value.codeUnits.fold(7, (h, c) => ((h * 31) + c) & 0x7fffffff);
int topicNoticeId(String pair, String topic) =>
    noticeId('message:$pair:$topic');
int reactionNoticeId(String pair, String message) =>
    noticeId('reaction:$pair:$message');

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
      try {
        await showConversation(
          api,
          state,
          data['pairId'] as String,
          data['topicId'] as String,
          alert: false,
        );
        return;
      } catch (_) {
        // Fall back to a simple confirmation below.
      }
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

String _line(Map<String, dynamic> message) => switch (message['kind']) {
  'image' => '📷 Photo',
  'video' => '🎥 Video',
  _ => message['text'] as String? ?? '',
};

/// Renders run one at a time, so a slow render can't overwrite a newer one.
Future<void> _renders = Future.value();

/// Shows every unread message in a topic as one conversation notification,
/// with replies sent from the notification included. [alert] is false when
/// refreshing after your own reply, so the update arrives silently.
Future<void> showConversation(
  AidaApi api,
  Map<String, dynamic> state,
  String pairId,
  String topicId, {
  required bool alert,
}) {
  final render = _renders.then(
    (_) => _renderConversation(api, state, pairId, topicId, alert: alert),
  );
  _renders = render.catchError((_) {});
  return render;
}

Future<void> _renderConversation(
  AidaApi api,
  Map<String, dynamic> state,
  String pairId,
  String topicId, {
  required bool alert,
}) async {
  final id = topicNoticeId(pairId, topicId);
  final unread = await api.unread(topicId);
  final messages = (unread['messages'] as List).cast<Map<String, dynamic>>();
  final myId = (state['user'] as Map)['id'];
  if (!messages.any((m) => m['senderId'] != myId)) {
    await _notices.cancel(id: id);
    return;
  }
  final partner = (state['pair'] as Map)['partner'] as Map<String, dynamic>;
  final partnerName = unread['partnerName'] as String;
  final topicName = unread['topicName'] as String;
  Uint8List? photo;
  final photoAt = partner['photoAt'] as int?;
  if (photoAt != null) {
    try {
      final bytes = await api.photoBytes(partner['id'] as String, photoAt);
      if (bytes != null) photo = Uint8List.fromList(bytes);
    } catch (_) {
      // The initial-less default icon is fine when the photo can't load.
    }
  }
  final them = Person(
    key: partner['id'] as String,
    name: partnerName,
    important: true,
    icon: photo == null ? null : ByteArrayAndroidIcon(photo),
  );
  final named = topicId != 'general';
  await _notices.show(
    id: id,
    title: named ? '$partnerName · $topicName' : partnerName,
    body: _line(messages.last),
    payload: jsonEncode({
      'type': 'message',
      'pairId': pairId,
      'topicId': topicId,
    }),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'aida_messages_v2',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
        color: const Color(0xFF6B5BA5),
        visibility: NotificationVisibility.private,
        category: AndroidNotificationCategory.message,
        silent: !alert,
        largeIcon: photo == null ? null : ByteArrayAndroidBitmap(photo),
        number: unread['unreadCount'] as int?,
        styleInformation: MessagingStyleInformation(
          const Person(name: 'You'),
          conversationTitle: named ? topicName : null,
          groupConversation: named,
          messages: [
            for (final message in messages)
              Message(
                _line(message),
                DateTime.fromMillisecondsSinceEpoch(
                  message['createdAt'] as int,
                ),
                message['senderId'] == myId ? null : them,
              ),
          ],
        ),
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
    if (data['type'] == 'message_deleted') {
      // Take down anything that still shows the deleted message.
      final pairId = data['pairId'] as String;
      final messageId = data['messageId'].toString();
      await _notices.cancel(id: reactionNoticeId(pairId, messageId));
      final seenKey = 'notice_${pairId}_${data['topicId']}';
      if (await _storage.read(key: seenKey) == messageId) {
        await _notices.cancel(
          id: topicNoticeId(pairId, data['topicId'] as String),
        );
      }
      return;
    }
    if (data['type'] == 'reaction') {
      final pairId = data['pairId'] as String;
      final item = await api.message(data['messageId'].toString());
      final myId = (state['user'] as Map)['id'];
      final id = reactionNoticeId(pairId, item['id'].toString());
      final reaction = ((item['reactions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .where((r) => r['userId'] != myId)
          .firstOrNull;
      if (item['senderId'] != myId ||
          item['deleted'] == true ||
          reaction == null) {
        await _notices.cancel(id: id);
        return;
      }
      final name = (pair!['partner'] as Map)['name'] as String;
      final about = switch (item['kind']) {
        'image' => 'your photo',
        'video' => 'your video',
        _ => '“${(item['text'] as String).replaceAll(RegExp(r'\s+'), ' ')}”',
      };
      await _notices.show(
        id: id,
        title: '$name reacted ${reaction['emoji']}',
        body: 'to $about',
        payload: jsonEncode({
          'type': 'message',
          'pairId': pairId,
          'topicId': item['topicId'],
        }),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'aida_messages_v2',
            'Messages',
            importance: Importance.defaultImportance,
            color: const Color(0xFF6B5BA5),
            visibility: NotificationVisibility.private,
            category: AndroidNotificationCategory.social,
            onlyAlertOnce: true,
          ),
        ),
      );
      return;
    }
    if (data['type'] == 'message') {
      final item = await api.message(data['messageId'].toString());
      if (item['senderId'] == (state['user'] as Map)['id']) return;
      if (item['deleted'] == true) return;
      final topicId = item['topicId'] as String;
      final seenKey = 'notice_${data['pairId']}_$topicId';
      final last = int.tryParse(await _storage.read(key: seenKey) ?? '') ?? 0;
      if ((item['id'] as int) <= last) return;
      await showConversation(
        api,
        state,
        data['pairId'] as String,
        topicId,
        alert: true,
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

  /// Decides whether a push received while Aida is open is shown.
  bool Function(Map<String, dynamic> data)? showInForeground;

  /// Whether the server can reach this device when Aida is closed.
  bool get pushActive => firebaseReady && serverReady;
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
        if (event.data['type'] == 'message_deleted') {
          unawaited(showRemoteEvent(event.data));
        } else if (event.data['type'] == 'message' &&
            (showInForeground?.call(event.data) ?? true)) {
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
