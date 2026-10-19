import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gal/gal.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import 'api.dart';
import 'call_screen.dart';
import 'media_view.dart';
import 'design.dart';
import 'moments_screen.dart';
import 'notifications.dart';
import 'us_screen.dart';

void main() => runApp(const AidaApp());

class AidaApp extends StatefulWidget {
  const AidaApp({super.key});

  @override
  State<AidaApp> createState() => _AidaAppState();
}

class _AidaAppState extends State<AidaApp> with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  static const _defaultUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );
  static const _googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  static const _preview =
      kDebugMode && bool.fromEnvironment('AIDA_DESIGN_PREVIEW');
  static const _version = 'Aida 2.2.0';

  final _nameController = TextEditingController();
  final _inviteController = TextEditingController();
  final _messageController = TextEditingController();
  final _messageFocus = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _uuid = const Uuid();
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  final _notifications = AidaNotifications();
  bool _foreground = true;
  String _topicId = 'general';
  List<Map<String, dynamic>> _topics = [
    {'id': 'general', 'name': 'Everyday'},
  ];
  int _messageGeneration = 0;
  String? _dismissedCallId;
  AidaApi? _api;
  IOWebSocketChannel? _socket;
  StreamSubscription? _socketSubscription;
  Timer? _pollTimer;
  Timer? _presenceTimer;
  Timer? _typingIdleTimer;
  Timer? _partnerTypingTimer;
  bool _liveReady = false;
  bool _typingAnnounced = false;
  bool _partnerTyping = false;
  int _lastTypingSent = 0;
  int _partnerDelivered = 0;
  int _partnerRead = 0;
  final Map<String, int> _deliveredAcks = {};
  final Map<String, int> _readAcks = {};
  bool _loading = true;
  bool _refreshing = false;
  bool _busy = false;
  bool _callScreenOpen = false;
  bool _googleInitialized = false;
  String? _problem;
  Map<String, dynamic>? _state;
  Map<String, dynamic>? _call;
  List<Map<String, dynamic>> _messages = [];
  String? _loadedPairId;
  double? _uploadProgress;
  ThemeMode _themeMode = ThemeMode.system;
  AidaAccent _accent = AidaAccent.lavender;

  /// Messages that arrived while the conversation was open; only these get
  /// an entrance animation, never history loaded on open or topic switch.
  final Set<int> _freshIds = {};

  /// The message being replied to, shown above the composer until sent.
  Map<String, dynamic>? _replyTo;
  int? _highlightId;
  Timer? _highlightTimer;
  final Map<int, GlobalKey> _messageKeys = {};

  /// Change-feed cursor for the open topic; null until it first loads.
  int? _changeSeq;

  /// The message being edited in the composer, and the draft it set aside.
  Map<String, dynamic>? _editing;
  String _draftBeforeEdit = '';
  String? _uploadLabel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messageFocus.addListener(() {
      if (!_messageFocus.hasFocus) _stopTyping();
    });
    _scrollController.addListener(_ackVisibleMessages);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notifications.dispose();
    _pollTimer?.cancel();
    _presenceTimer?.cancel();
    _typingIdleTimer?.cancel();
    _partnerTypingTimer?.cancel();
    _highlightTimer?.cancel();
    _socketSubscription?.cancel();
    _socket?.sink.close();
    _api?.close();
    _nameController.dispose();
    _inviteController.dispose();
    _messageController.dispose();
    _messageFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    if (_preview) {
      _api = AidaApi('https://preview.invalid', token: 'preview-only');
      _state = {
        'user': {'id': 'me', 'name': 'Yash'},
        'pair': {
          'id': 'preview',
          'partner': {'id': 'them', 'name': 'Sofia', 'online': true},
          'createdAt': DateTime.now()
              .subtract(const Duration(days: 141))
              .millisecondsSinceEpoch,
        },
      };
      _liveReady = true;
      _partnerRead = 3;
      _partnerDelivered = 5;
      _topics = [
        {'id': 'general', 'name': 'Everyday'},
        {'id': 'trip', 'name': 'Summer in Italy'},
        {'id': 'movies', 'name': 'Movie nights'},
      ];
      _messages = [
        {
          'id': 1,
          'senderId': 'them',
          'kind': 'text',
          'text': 'Found the little café I told you about ☕',
          'createdAt': DateTime.now().millisecondsSinceEpoch - 180000,
        },
        {
          'id': 2,
          'senderId': 'them',
          'kind': 'text',
          'text': 'Saving you a seat for when you get here.',
          'createdAt': DateTime.now().millisecondsSinceEpoch - 120000,
          'kept': true,
          'keptBy': 'me',
        },
        {
          'id': 3,
          'senderId': 'me',
          'kind': 'text',
          'text': 'Already my favorite place.',
          'createdAt': DateTime.now().millisecondsSinceEpoch - 70000,
        },
        {
          'id': 5,
          'senderId': 'me',
          'kind': 'text',
          'text': 'Just because you’re there.',
          'createdAt': DateTime.now().millisecondsSinceEpoch - 60000,
          'editedAt': DateTime.now().millisecondsSinceEpoch - 50000,
          'reactions': [
            {'userId': 'them', 'emoji': '❤️'},
          ],
        },
        {
          'id': 6,
          'senderId': 'them',
          'kind': 'text',
          'text': 'Let’s put it in our Italy plans ✨',
          'replyToId': 3,
          'replyTo': {
            'id': 3,
            'senderId': 'me',
            'kind': 'text',
            'text': 'Already my favorite place.',
          },
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
      ];
      setState(() => _loading = false);
      return;
    }
    await _notifications.initialize();
    _notifications.onTap = _handleNotice;
    _notifications.showInForeground = (data) => foregroundPushShouldNotify(
      liveConnected: _liveReady,
      conversationVisible: _viewing(data),
    );
    await _restore();
    if (_api?.token != null) {
      unawaited(_registerNotifications());
      final notice = _notifications.pending;
      if (notice != null) await _handleNotice(notice);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _stopTyping();
    _sendPresence();
    if (_foreground && _api?.token != null) {
      _connectLive();
      unawaited(_refresh());
    }
  }

  void _sendLive(Map<String, dynamic> event) {
    if (!_liveReady) return;
    try {
      _socket?.sink.add(jsonEncode(event));
    } catch (_) {}
  }

  void _sendPresence() =>
      _sendLive({'type': 'presence', 'active': _foreground});

  void _typingChanged(String text) {
    if (!_foreground ||
        _editing != null ||
        !_messageFocus.hasFocus ||
        _loadedPairId == null ||
        text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_typingAnnounced || now - _lastTypingSent >= 1500) {
      _sendLive({
        'type': 'typing',
        'pairId': _loadedPairId,
        'topicId': _topicId,
        'typing': true,
      });
      _lastTypingSent = now;
      _typingAnnounced = true;
    }
    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(const Duration(seconds: 3), _stopTyping);
  }

  void _stopTyping() {
    _typingIdleTimer?.cancel();
    if (_typingAnnounced) {
      _sendLive({
        'type': 'typing',
        'pairId': _loadedPairId,
        'topicId': _topicId,
        'typing': false,
      });
    }
    _typingAnnounced = false;
  }

  void _clearPartnerTyping() {
    _partnerTypingTimer?.cancel();
    _partnerTyping = false;
  }

  void _applyReceipt(Map<String, dynamic> receipt) {
    final delivered = (receipt['deliveredThrough'] as int?) ?? 0;
    final read = (receipt['readThrough'] as int?) ?? 0;
    if (delivered > _partnerDelivered) _partnerDelivered = delivered;
    if (read > _partnerRead) _partnerRead = read;
  }

  /// Whether this exact conversation is on screen right now, so a new
  /// message in it needs no system notification.
  bool _viewing(Map<String, dynamic> event) =>
      _foreground &&
      !_callScreenOpen &&
      _navigatorKey.currentState?.canPop() == false &&
      event['pairId'] == _loadedPairId &&
      (event['topicId'] ?? 'general') == _topicId;

  void _ackVisibleMessages() {
    if (_preview) return;
    unawaited(_ackMessages());
  }

  Future<void> _ackMessages({bool allowRead = true}) async {
    final api = _api;
    final pairId = _loadedPairId;
    final topicId = _topicId;
    if (api?.token == null || pairId == null || _messages.isEmpty) return;
    final last = _messages.last['id'] as int;
    // The list is reversed: offset 0 is the newest message.
    final atBottom =
        _scrollController.hasClients && _scrollController.position.pixels < 40;
    final read =
        allowRead &&
            _foreground &&
            !_callScreenOpen &&
            _navigatorKey.currentState?.canPop() == false &&
            atBottom
        ? last
        : 0;
    final key = '$pairId/$topicId';
    if ((_deliveredAcks[key] ?? 0) >= last && (_readAcks[key] ?? 0) >= read) {
      return;
    }
    // Reserve before awaiting so scroll events don't submit duplicate requests.
    final oldDelivered = _deliveredAcks[key] ?? 0;
    final oldRead = _readAcks[key] ?? 0;
    _deliveredAcks[key] = last;
    if (read > oldRead) {
      _readAcks[key] = read;
      // Read in the app, so its notification no longer needs attention.
      unawaited(_notifications.cancelTopic(pairId, topicId));
    }
    try {
      await api!.acknowledgeMessages(
        pairId: pairId,
        topicId: topicId,
        deliveredThrough: last,
        readThrough: read,
      );
    } catch (_) {
      // Retry on the next refresh; receipts must not interrupt composing.
      if (_deliveredAcks[key] == last) _deliveredAcks[key] = oldDelivered;
      if (_readAcks[key] == read) _readAcks[key] = oldRead;
    }
  }

  String _presenceLabel(Map<String, dynamic> partner) {
    if (!_liveReady) return 'Connecting…';
    if (partner['online'] == true) return 'Online';
    final stamp = partner['lastSeenAt'] as int?;
    if (stamp == null) return 'Offline';
    final seen = DateTime.fromMillisecondsSinceEpoch(stamp);
    final age = DateTime.now().difference(seen);
    if (age.inMinutes < 1) return 'Last seen just now';
    if (age.inHours < 1) return 'Last seen ${age.inMinutes}m ago';
    if (age.inHours < 24) return 'Last seen ${age.inHours}h ago';
    return 'Last seen ${seen.day}/${seen.month}/${seen.year}';
  }

  Future<void> _registerNotifications() async {
    try {
      await _notifications.register(_api!);
      if (mounted) setState(() {});
    } catch (_) {
      /* The chat remains available if notification permission is denied. */
    }
  }

  Future<void> _handleNotice(NotificationResponse response) async {
    if (_api?.token == null) return;
    _notifications.pending = null;
    await performNotificationAction(response);
    final data = jsonDecode(response.payload ?? '{}') as Map<String, dynamic>;
    await _refresh();
    if ((_state?['pair'] as Map?)?['id'] != data['pairId']) return;
    if (data['type'] == 'message') {
      await _switchTopic(data['topicId'] as String? ?? 'general');
      if (data['draft'] != null) {
        _messageController.text = data['draft'] as String;
      }
    } else if (data['type'] == 'call' && _call?['id'] == data['callId']) {
      if (response.actionId == 'answer' && _call?['state'] == 'ringing') {
        try {
          await _api!.callAction(data['callId'] as String, 'accept');
        } catch (_) {}
        await _refresh();
      }
      await _openCall();
    }
  }

  Future<void> _switchTopic(String id) async {
    if (!_topics.any((topic) => topic['id'] == id)) return;
    _stopTyping();
    _clearPartnerTyping();
    _partnerDelivered = _partnerRead = 0;
    _messageGeneration++;
    setState(() {
      _topicId = id;
      _messages = [];
      _freshIds.clear();
      _messageKeys.clear();
      _replyTo = null;
      _editing = null;
      _changeSeq = null;
    });
    if (_loadedPairId != null) {
      await _storage.write(key: 'topic_$_loadedPairId', value: id);
      await _notifications.cancelTopic(_loadedPairId!, id);
    }
    await _loadMessages();
  }

  Future<void> _createTopic() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('A space for something'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Topic name',
            hintText: 'Trip to Italy, Movie nights…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create topic'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || _loadedPairId == null) return;
    await _run(() async {
      final topic = await _api!.createTopic(name, _loadedPairId!);
      await _refresh();
      await _switchTopic(topic['id'] as String);
    });
  }

  Future<void> _restore() async {
    final mode = await _storage.read(key: 'theme_mode');
    _themeMode = ThemeMode.values.firstWhere(
      (value) => value.name == mode,
      orElse: () => ThemeMode.system,
    );
    _accent = AidaAccent.named(await _storage.read(key: 'accent'));
    final url = await _storage.read(key: 'api_url') ?? _defaultUrl;
    final token = await _storage.read(key: 'session_token');
    _api = AidaApi(url, token: token);
    await _storage.write(key: 'api_url', value: url);
    if (token != null) {
      await _refresh();
      _connectLive();
    }
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_api?.token != null) _refresh();
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    try {
      await _storage.write(key: 'theme_mode', value: mode.name);
    } catch (_) {
      // Appearance is a convenience; the choice still applies this session.
    }
  }

  Future<void> _setAccent(AidaAccent accent) async {
    setState(() => _accent = accent);
    try {
      await _storage.write(key: 'accent', value: accent.name);
    } catch (_) {}
  }

  /// Leaves Us/Moments once the account or connection they describe is gone.
  void _returnHome() =>
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);

  void _showError(Object error) {
    if (!mounted) return;
    final message = error is ApiException ? error.message : error.toString();
    setState(() => _problem = message);
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api?.token == null || _refreshing) return;
    _refreshing = true;
    try {
      final state = await api!.me();
      final pair = state['pair'] as Map<String, dynamic>?;
      final pairId = pair?['id'] as String?;
      if (!mounted) return;
      if (pairId != _loadedPairId) {
        _stopTyping();
        _clearPartnerTyping();
        _partnerDelivered = _partnerRead = 0;
        _deliveredAcks.clear();
        _readAcks.clear();
        _messageGeneration++;
        _messages = [];
        _freshIds.clear();
        _messageKeys.clear();
        _replyTo = null;
        _editing = null;
        _changeSeq = null;
        _call = null;
        _loadedPairId = pairId;
        _topicId = pairId == null
            ? 'general'
            : await _storage.read(key: 'topic_$pairId') ?? 'general';
        if (pairId == null) await _notifications.clear();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
      setState(() {
        _state = state;
        _problem = null;
      });
      if (pairId != null) {
        final topics = (await api.topics())['topics'] as List;
        if (!mounted) return;
        setState(() => _topics = topics.cast<Map<String, dynamic>>());
        if (!_topics.any((topic) => topic['id'] == _topicId)) {
          _topicId = 'general';
        }
        await _loadMessages();
        final currentCall = await api.currentCall();
        if (mounted) {
          final oldCall = _call;
          setState(() => _call = currentCall['call'] as Map<String, dynamic>?);
          if (oldCall != null &&
              (oldCall['id'] != _call?['id'] || _call?['state'] != 'ringing')) {
            await _notifications.cancelCall(oldCall['id'] as String);
          }
          if (_foreground &&
              _call != null &&
              _call!['id'] != _dismissedCallId) {
            unawaited(_notifications.cancelCall(_call!['id'] as String));
            unawaited(_openCall());
          } else if (!_foreground && _call?['state'] == 'ringing') {
            unawaited(
              showRemoteEvent({
                'type': 'call',
                'pairId': pairId,
                'callId': _call!['id'],
              }),
            );
          }
        }
      }
    } on ApiException catch (error) {
      if (error.status == 401) {
        await _storage.delete(key: 'session_token');
        api?.token = null;
        _stopLive();
        if (mounted) setState(() => _state = null);
      } else if (mounted) {
        setState(() => _problem = error.message);
      }
    } catch (error) {
      if (mounted) setState(() => _problem = 'Cannot reach the server');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _loadMessages() async {
    final api = _api!;
    final generation = _messageGeneration;
    final topicId = _topicId;
    final pairId = _loadedPairId;
    final followLatest =
        _messages.isEmpty ||
        !_scrollController.hasClients ||
        _scrollController.position.pixels < 80;
    final fromScratch = _messages.isEmpty;
    var cursor = fromScratch ? 0 : _messages.last['id'] as int;
    while (true) {
      final page = await api.messages(after: cursor, topicId: topicId);
      if (!mounted ||
          generation != _messageGeneration ||
          pairId != _loadedPairId) {
        return;
      }
      if (fromScratch && cursor == 0) _changeSeq = page['changeSeq'] as int?;
      final items = (page['messages'] as List).cast<Map<String, dynamic>>();
      final receipt = page['partnerReceipt'] as Map<String, dynamic>?;
      if (receipt != null) setState(() => _applyReceipt(receipt));
      if (items.isNotEmpty && mounted) {
        final latest = _messages.isEmpty ? 0 : _messages.last['id'] as int;
        final fresh = items
            .where((item) => (item['id'] as int) > latest)
            .toList();
        setState(() {
          if (_messages.isNotEmpty) {
            _freshIds.addAll(fresh.map((item) => item['id'] as int));
          }
          _messages.addAll(fresh);
        });
        cursor = items.last['id'] as int;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              generation == _messageGeneration &&
              followLatest &&
              _scrollController.hasClients) {
            _scrollController.jumpTo(0);
          }
        });
      }
      if (page['hasMore'] != true || items.isEmpty) break;
    }
    await _syncChanges(generation, topicId, pairId);
    if (!mounted || generation != _messageGeneration) return;
    // Delivery is independent of rendering; a background sync is not a read.
    await _ackMessages(allowRead: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _messageGeneration) _ackVisibleMessages();
    });
  }

  /// Applies edits, deletions, reactions, and keeps made since the last sync.
  Future<void> _syncChanges(
    int generation,
    String topicId,
    String? pairId,
  ) async {
    var since = _changeSeq;
    // Servers before 2.2 have no change feed.
    if (since == null) return;
    while (true) {
      final page = await _api!.changes(since: since!, topicId: topicId);
      if (!mounted ||
          generation != _messageGeneration ||
          pairId != _loadedPairId) {
        return;
      }
      final items = (page['messages'] as List).cast<Map<String, dynamic>>();
      for (final item in items) {
        _replaceMessage(item);
      }
      since = page['seq'] as int;
      _changeSeq = since;
      if (page['hasMore'] != true) break;
    }
  }

  void _connectLive() {
    _stopLive();
    if (_api?.token == null) return;
    try {
      final channel = _api!.live();
      _socket = channel;
      _socketSubscription = channel.stream.listen(
        (raw) {
          final event = jsonDecode(raw as String) as Map<String, dynamic>;
          if (event['type'] == 'connected') {
            setState(() => _liveReady = true);
            _sendPresence();
            _presenceTimer?.cancel();
            _presenceTimer = Timer.periodic(
              const Duration(seconds: 20),
              (_) => _sendPresence(),
            );
          }
          if ([
            'typing',
            'presence',
            'receipts_changed',
          ].contains(event['type'])) {
            if (event['pairId'] != _loadedPairId) return;
            if (event['type'] == 'typing' && event['topicId'] == _topicId) {
              _partnerTypingTimer?.cancel();
              setState(() => _partnerTyping = event['typing'] == true);
              if (_partnerTyping) {
                _partnerTypingTimer = Timer(const Duration(seconds: 5), () {
                  if (mounted) setState(() => _partnerTyping = false);
                });
              }
            } else if (event['type'] == 'presence') {
              final partner = (_state?['pair'] as Map?)?['partner'] as Map?;
              if (partner?['id'] == event['userId']) {
                setState(() {
                  partner!['online'] = event['online'];
                  partner['lastSeenAt'] = event['lastSeenAt'];
                  if (event['online'] != true) _clearPartnerTyping();
                });
              }
            } else if (event['type'] == 'receipts_changed' &&
                event['topicId'] == _topicId) {
              setState(() => _applyReceipt(event));
            }
            return;
          }
          unawaited(_refresh());
          if (event['type'] == 'messages_changed' &&
              event['messageId'] != null &&
              socketShouldNotify(
                foreground: _foreground,
                conversationVisible: _viewing(event),
                pushActive: _notifications.pushActive,
              )) {
            unawaited(showRemoteEvent({...event, 'type': 'message'}));
          }
        },
        onError: (_) {},
        onDone: () {
          _presenceTimer?.cancel();
          if (mounted) {
            setState(() {
              _liveReady = false;
              _clearPartnerTyping();
            });
          }
          _socket = null;
          _socketSubscription = null;
          if (mounted && _api?.token != null) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && _socket == null) _connectLive();
            });
          }
        },
      );
    } catch (_) {
      // Periodic refresh keeps the app usable while the socket reconnects.
    }
  }

  void _stopLive() {
    _stopTyping();
    _presenceTimer?.cancel();
    _liveReady = false;
    _clearPartnerTyping();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.sink.close();
    _socket = null;
  }

  Future<void> _serverSettings() async {
    final controller = TextEditingController(
      text: _api?.baseUrl ?? _defaultUrl,
    );
    final result = await showDialog<String>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'API URL',
            hintText: 'https://chat.example.com',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final uri = Uri.tryParse(result);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      _showError(const FormatException('Enter a full http or https address'));
      return;
    }
    _stopLive();
    await _notifications.clear();
    _api?.close();
    await _storage.write(key: 'api_url', value: result);
    await _storage.delete(key: 'session_token');
    setState(() {
      _api = AidaApi(result);
      _state = null;
      _messages = [];
      _loadedPairId = null;
      _problem = null;
    });
    _returnHome();
  }

  Future<void> _googleSignIn() => _run(() async {
    if (_googleWebClientId.isEmpty) {
      throw const FormatException(
        'Google sign-in needs GOOGLE_WEB_CLIENT_ID in the Android build',
      );
    }
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId: _googleWebClientId,
      );
      _googleInitialized = true;
    }
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const FormatException('Google did not return a sign-in token');
    }
    final result = await _api!.signInWithGoogle(idToken);
    final token = result['token'] as String;
    await _storage.write(key: 'session_token', value: token);
    _api!.token = token;
    await _refresh();
    _connectLive();
    unawaited(_registerNotifications());
  });

  Future<void> _signOut() => _run(() async {
    try {
      await _api!.signOut();
    } catch (_) {}
    if (_googleInitialized) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    _stopLive();
    await _notifications.clear();
    await _storage.delete(key: 'session_token');
    _api!.token = null;
    setState(() {
      _state = null;
      _messages = [];
      _call = null;
    });
    _returnHome();
  });

  Future<void> _createInvite() => _run(() async {
    await _api!.createInvite();
    await _refresh();
  });

  Future<void> _acceptInvite() => _run(() async {
    final code = _inviteController.text.trim().toUpperCase();
    final invite = await _api!.lookupInvite(code);
    if (!mounted) return;
    final inviter = invite['inviter'] as Map<String, dynamic>;
    final accepted = await showDialog<bool>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Connect?'),
        content: Text(
          'Connect with ${inviter['name']}? '
          'You can only have one partner at a time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    await _api!.acceptInvite(code);
    _inviteController.clear();
    await _refresh();
  });

  Future<void> _changeName() async {
    _nameController.text =
        (_state?['user'] as Map<String, dynamic>?)?['name']?.toString() ?? '';
    final name = await showDialog<String>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: _nameController, maxLength: 40),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _nameController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null) return;
    await _run(() async {
      await _api!.setName(name);
      await _refresh();
    });
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text(
          'This ends your connection and deletes this conversation for both of you. '
          'Messages and media cannot be restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep connection'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _api!.disconnect();
      _messages = [];
      _call = null;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await _refresh();
      _returnHome();
    });
  }

  Future<void> _sendText() => _run(() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final reply = _replyTo;
    _stopTyping();
    _messageController.clear();
    setState(() => _replyTo = null);
    try {
      await _api!.sendMessage(
        text,
        _uuid.v4(),
        topicId: _topicId,
        pairId: _loadedPairId,
        replyToId: reply?['id'] as int?,
      );
      await _loadMessages();
    } catch (_) {
      _messageController.text = text;
      if (mounted && _replyTo == null) setState(() => _replyTo = reply);
      rethrow;
    }
  });

  /// The sheet behind the composer's "+": camera, video, or gallery.
  Future<void> _attach(String partnerName, String topicName) async {
    _messageFocus.unfocus();
    final choice = await showModalBottomSheet<String>(
      context: _navigatorKey.currentContext!,
      builder: (context) {
        final c = context.aida;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Share with $partnerName',
                  style: TextStyle(
                    fontFamily: serif,
                    fontSize: 28,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'In $topicName',
                  style: TextStyle(color: c.muted, fontSize: 13),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _AttachTile(
                        icon: Icons.photo_camera_rounded,
                        label: 'Camera',
                        caption: 'Take a photo',
                        tint: c.accent,
                        onTap: () => Navigator.pop(context, 'camera'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _AttachTile(
                        icon: Icons.videocam_rounded,
                        label: 'Video',
                        caption: 'Record a clip',
                        tint: c.warm,
                        onTap: () => Navigator.pop(context, 'video'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _AttachTile(
                        icon: Icons.photo_library_rounded,
                        label: 'Gallery',
                        caption: 'Up to 10 at once',
                        tint: c.online,
                        onTap: () => Navigator.pop(context, 'gallery'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    switch (choice) {
      case 'camera':
        await _capture(video: false);
      case 'video':
        await _capture(video: true);
      case 'gallery':
        await _pickGallery();
    }
  }

  /// Opens the phone's own camera app; photos are resized like gallery picks
  /// so they send quickly.
  Future<void> _capture({required bool video}) async {
    if (_busy) return;
    final XFile? picked;
    try {
      picked = video
          ? await _picker.pickVideo(
              source: ImageSource.camera,
              maxDuration: const Duration(minutes: 1),
            )
          : await _picker.pickImage(
              source: ImageSource.camera,
              maxWidth: 2560,
              maxHeight: 2560,
              imageQuality: 85,
            );
    } on PlatformException catch (error) {
      _showError(
        FormatException(
          error.code == 'camera_access_denied'
              ? 'Allow camera access for Aida in Android settings.'
              : 'The camera couldn’t open.',
        ),
      );
      return;
    }
    if (picked != null) await _uploadFiles([picked]);
  }

  Future<void> _pickGallery() async {
    if (_busy) return;
    final picked = await _picker.pickMultipleMedia(
      limit: 10,
      maxWidth: 2560,
      maxHeight: 2560,
      imageQuality: 85,
    );
    if (picked.isNotEmpty) await _uploadFiles(picked);
  }

  static String _mimeOf(XFile file) {
    final declared = file.mimeType;
    if (declared != null && declared.isNotEmpty) return declared;
    return switch (file.name.toLowerCase().split('.').last) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      'mov' => 'video/quicktime',
      _ => '',
    };
  }

  /// Sends each file in turn. A reply in progress attaches to the first.
  Future<void> _uploadFiles(List<XFile> files) => _run(() async {
    final uploadPair = _loadedPairId;
    final uploadTopic = _topicId;
    var reply = _replyTo;
    final skipped = <String>[];
    try {
      for (var i = 0; i < files.length; i++) {
        final picked = files[i];
        final file = File(picked.path);
        final mime = _mimeOf(picked);
        if (mime.isEmpty) {
          skipped.add('${picked.name} isn’t a photo or video Aida can send.');
          continue;
        }
        if (await file.length() > 100 * 1024 * 1024) {
          skipped.add(
            mime.startsWith('video/')
                ? 'A video was over 100 MB. Try a shorter clip.'
                : '${picked.name} is over 100 MB.',
          );
          continue;
        }
        final kind = mime.startsWith('video/') ? 'video' : 'photo';
        setState(() {
          _uploadProgress = 0;
          _uploadLabel = files.length > 1
              ? 'Sending ${i + 1} of ${files.length}…'
              : 'Sending $kind…';
        });
        await _api!.upload(
          file,
          mime,
          topicId: uploadTopic,
          pairId: uploadPair,
          replyToId: reply?['id'] as int?,
          onProgress: (fraction) {
            if (mounted) setState(() => _uploadProgress = fraction);
          },
        );
        if (mounted && identical(_replyTo, reply) && reply != null) {
          setState(() => _replyTo = null);
        }
        reply = null;
        await _loadMessages();
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploadProgress = null;
          _uploadLabel = null;
        });
      }
    }
    if (skipped.isNotEmpty) throw FormatException(skipped.join('\n'));
  });

  Future<void> _startCall(String kind) => _run(() async {
    _dismissedCallId = null;
    final call = await _api!.startCall(kind);
    if (mounted) setState(() => _call = call);
    unawaited(_openCall());
  });

  Future<void> _callAction(String action) => _run(() async {
    final call = _call;
    if (call == null) return;
    await _api!.callAction(call['id'] as String, action);
    await _refresh();
    if (action == 'accept') _openCall();
  });

  Future<void> _openCall() async {
    final call = _call;
    if (call == null || _callScreenOpen) return;
    _stopTyping();
    _callScreenOpen = true;
    try {
      await _navigatorKey.currentState!.push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            api: _api!,
            call: call,
            myId: (_state!['user'] as Map)['id'] as String,
            partnerName:
                ((_state!['pair'] as Map<String, dynamic>)['partner']
                        as Map<String, dynamic>)['name']
                    as String,
          ),
        ),
      );
    } finally {
      _callScreenOpen = false;
      _dismissedCallId = call['id'] as String;
      await _refresh();
    }
  }

  Future<void> _enableNotifications() => _run(() async {
    await _registerNotifications();
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          !_notifications.permissionGranted
              ? 'Allow Aida notifications in Android settings to receive alerts.'
              : _notifications.firebaseReady && _notifications.serverReady
              ? 'Message and call notifications are enabled.'
              : 'Notifications are not available yet. Please try again later.',
        ),
      ),
    );
  });

  void _openMoments() {
    final pair = _state?['pair'] as Map<String, dynamic>?;
    if (pair == null) return;
    _stopTyping();
    _navigatorKey.currentState!
        .push(
          MaterialPageRoute(
            builder: (_) => MomentsScreen(
              api: _api!,
              since: pair['createdAt'] as int?,
              myId: _myId,
              myName: (_state!['user'] as Map)['name']?.toString() ?? '',
              partnerName: (pair['partner'] as Map)['name']?.toString() ?? '',
              preview: _preview ? _previewMedia : null,
              previewKept: _preview
                  ? _messages.where((m) => m['kept'] == true).toList()
                  : null,
            ),
          ),
        )
        .then((_) => _ackVisibleMessages());
  }

  void _openUs() {
    _stopTyping();
    _navigatorKey.currentState!
        .push(
          MaterialPageRoute(
            builder: (_) => UsScreen(
              state: () => _state,
              presence: _presenceLabel,
              themeMode: () => _themeMode,
              accent: () => _accent,
              onThemeMode: _setThemeMode,
              onAccent: _setAccent,
              onChangeName: _changeName,
              onNotifications: _enableNotifications,
              onServer: _serverSettings,
              onSignOut: _signOut,
              onDisconnect: _disconnect,
              version: _version,
            ),
          ),
        )
        .then((_) => _ackVisibleMessages());
  }

  static final _previewMedia = [
    for (var i = 0; i < 7; i++)
      {
        'id': 100 + i,
        'kind': i == 2 ? 'video' : 'image',
        'mediaId': 'preview-$i',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aida',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      theme: aidaTheme(Brightness.light, _accent),
      darkTheme: aidaTheme(Brightness.dark, _accent),
      themeMode: _themeMode,
      home: Builder(
        builder: (context) => _loading
            ? const Scaffold(body: Center(child: AidaMark(breathing: true)))
            : _api?.token == null
            ? _authScreen(context)
            : _state == null
            ? _connectionScreen(context)
            : _state?['pair'] == null
            ? _unpairedScreen(context)
            : _chatScreen(context),
      ),
    );
  }

  Widget _authScreen(BuildContext context) {
    final c = context.aida;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              children: [
                Row(
                  children: [
                    Text(
                      'aida',
                      style: TextStyle(
                        fontFamily: serif,
                        fontSize: 34,
                        color: c.ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Server settings',
                      onPressed: _serverSettings,
                      icon: Icon(Icons.tune_rounded, size: 21, color: c.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Container(
                  height: 236,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [c.accentSoft, c.background],
                      radius: .85,
                    ),
                    borderRadius: BorderRadius.circular(120),
                  ),
                  child: const Center(
                    child: AidaMark(size: 132, breathing: true),
                  ),
                ),
                const SizedBox(height: 40),
                const Eyebrow('A little closer'),
                const SizedBox(height: 14),
                Text(
                  'Your person.\nYour little world.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                Text(
                  'The everyday stories, the big plans, and the calls that make the distance feel smaller.',
                  style: TextStyle(color: c.muted, fontSize: 16, height: 1.6),
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _busy ? null : _googleSignIn,
                  icon: const Icon(Icons.account_circle_outlined),
                  label: Text(_busy ? 'Signing in…' : 'Continue with Google'),
                ),
                const SizedBox(height: 18),
                Text(
                  'One connection. A space just for you two.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
                if (_problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Text(
                      _problem!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.danger),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionScreen(BuildContext context) {
    final c = context.aida;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AidaMark(size: 64, breathing: true),
                const SizedBox(height: 24),
                Text(
                  _problem == null ? 'Finding your space…' : 'Can’t connect',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  _problem ?? 'Connecting to your server.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted),
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: _refresh, child: const Text('Retry')),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _serverSettings,
                  child: const Text('Change server address'),
                ),
                TextButton(onPressed: _signOut, child: const Text('Sign out')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _unpairedScreen(BuildContext context) {
    final c = context.aida;
    final user = (_state?['user'] as Map<String, dynamic>?) ?? {};
    final code = (_state?['invite'] as Map?)?['code']?.toString();
    final soft = c.onHero.withValues(alpha: .64);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'aida',
          style: TextStyle(
            fontFamily: serif,
            fontSize: 32,
            fontWeight: FontWeight.w400,
            color: c.ink,
          ),
        ),
        actions: [_accountMenu(), const SizedBox(width: 6)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: PersonAvatar(user['name']?.toString() ?? 'A', size: 64),
              ),
              const SizedBox(height: 24),
              Text(
                'Hi, ${user['name'] ?? 'there'}.\nMake room for two.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 14),
              Text(
                'Invite your person into a shared space for conversations, plans, and being together.',
                style: TextStyle(color: c.muted, height: 1.6),
              ),
              const SizedBox(height: 30),
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: c.hero,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: AidaMark(
                          size: 44,
                          breathing: code != null,
                          first: c.onHero,
                          second: c.warm,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        code == null
                            ? 'It starts with an invitation.'
                            : 'Your invitation is ready.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: serif,
                          color: c.onHero,
                          fontSize: 28,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (code == null) ...[
                        Text(
                          'Only the person who accepts your code can join you.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: soft),
                        ),
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: _busy ? null : _createInvite,
                          style: FilledButton.styleFrom(
                            backgroundColor: c.warm,
                            foregroundColor: night,
                          ),
                          child: const Text('Create invite'),
                        ),
                      ] else ...[
                        SelectableText(
                          code,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            letterSpacing: 4,
                            fontSize: 26,
                            fontWeight: FontWeight.w500,
                            color: c.warm,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'One use · Expires in 24 hours',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: soft, fontSize: 12),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Copy code',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: code));
                                _messengerKey.currentState?.showSnackBar(
                                  const SnackBar(
                                    content: Text('Invite code copied'),
                                  ),
                                );
                              },
                              icon: Icon(Icons.copy_rounded, color: c.onHero),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: c.warm,
                                foregroundColor: night,
                              ),
                              onPressed: () => SharePlus.instance.share(
                                ShareParams(
                                  text:
                                      'Join me on Aida. My invite code is $code',
                                ),
                              ),
                              icon: const Icon(Icons.ios_share_rounded),
                              label: const Text('Share invite'),
                            ),
                          ],
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await _api!.revokeInvite();
                                  await _refresh();
                                }),
                          child: Text(
                            'Revoke invite',
                            style: TextStyle(color: soft),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Already have an invite?',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _inviteController,
                textCapitalization: TextCapitalization.characters,
                maxLength: 10,
                decoration: InputDecoration(
                  hintText: 'Enter their code',
                  prefixIcon: Icon(Icons.key_outlined, color: c.muted),
                ),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _acceptInvite,
                style: FilledButton.styleFrom(
                  backgroundColor: c.accentSoft,
                  foregroundColor: c.accent,
                ),
                child: const Text('Review invitation'),
              ),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(_problem!, style: TextStyle(color: c.danger)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accountMenu() => PopupMenuButton<String>(
    tooltip: 'Your account',
    icon: const Icon(Icons.more_horiz_rounded),
    position: PopupMenuPosition.under,
    onSelected: (value) {
      if (value == 'name') _changeName();
      if (value == 'signout') _signOut();
      if (value == 'server') _serverSettings();
      if (value == 'notifications') _enableNotifications();
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'name', child: Text('Your name')),
      PopupMenuItem(
        value: 'notifications',
        child: Text('Enable notifications'),
      ),
      PopupMenuItem(value: 'server', child: Text('Server settings')),
      PopupMenuItem(value: 'signout', child: Text('Sign out')),
      PopupMenuItem(enabled: false, child: Text(_version)),
    ],
  );

  Widget _menuRow(AidaColors c, IconData icon, String title, [String? hint]) =>
      Row(
        children: [
          Icon(icon, size: 21, color: c.accent),
          const SizedBox(width: 14),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(color: c.ink, fontSize: 15)),
                if (hint != null)
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      );

  Widget _chatScreen(BuildContext context) {
    final c = context.aida;
    final pair = _state!['pair'] as Map<String, dynamic>;
    final partner = pair['partner'] as Map<String, dynamic>;
    final user = _state!['user'] as Map<String, dynamic>;
    final online = _liveReady && partner['online'] == true;
    final topicName =
        _topics.firstWhere(
              (t) => t['id'] == _topicId,
              orElse: () => {'name': 'Everyday'},
            )['name']
            as String;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: 8,
        title: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: _openUs,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      PersonAvatar(partner['name'] as String, size: 42),
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: AnimatedScale(
                          scale: online ? 1 : 0,
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutBack,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: c.online,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.background, width: 2),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          partner['name'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: serif,
                            fontSize: 26,
                            fontWeight: FontWeight.w400,
                            height: 1.1,
                            color: c.ink,
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...previous, ?current],
                          ),
                          child: Text(
                            _partnerTyping
                                ? 'typing…'
                                : _presenceLabel(partner),
                            key: ValueKey(_partnerTyping),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _partnerTyping ? c.accent : c.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Voice call',
            onPressed: _call == null && !_busy
                ? () => _startCall('voice')
                : null,
            icon: const Icon(Icons.call_outlined, size: 22),
          ),
          IconButton(
            tooltip: 'Video call',
            onPressed: _call == null && !_busy
                ? () => _startCall('video')
                : null,
            icon: const Icon(Icons.videocam_outlined, size: 25),
          ),
          PopupMenuButton<String>(
            tooltip: 'Moments and Us',
            icon: const Icon(Icons.more_horiz_rounded),
            position: PopupMenuPosition.under,
            onSelected: (value) =>
                value == 'moments' ? _openMoments() : _openUs(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'moments',
                height: 60,
                child: _menuRow(
                  c,
                  Icons.photo_library_outlined,
                  'Moments',
                  'Photos and milestones',
                ),
              ),
              PopupMenuItem(
                value: 'us',
                height: 60,
                child: _menuRow(
                  c,
                  Icons.favorite_border_rounded,
                  'Us',
                  'Profile, themes, privacy',
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _topicBar(c),
          if (_call != null) _callBanner(c, user['id'] as String),
          if (_problem != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
              decoration: BoxDecoration(
                color: c.surfaceMuted,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded, size: 18, color: c.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _problem!,
                      style: TextStyle(color: c.muted, fontSize: 13),
                    ),
                  ),
                  TextButton(onPressed: _refresh, child: const Text('Retry')),
                ],
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? _emptyChat(c, topicName)
                : _messageList(
                    c,
                    user['id'] as String,
                    partner['name'] as String,
                  ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomLeft,
            child: _partnerTyping
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TypingBubble(name: partner['name'] as String),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          _composer(
            c,
            topicName,
            user['id'] as String,
            partner['name'] as String,
          ),
        ],
      ),
    );
  }

  Widget _topicBar(AidaColors c) => SizedBox(
    height: 48,
    child: Row(
      children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 6, 4, 8),
            children: [for (final topic in _topics) _topicPill(c, topic)],
          ),
        ),
        IconButton(
          tooltip: 'Create shared topic',
          onPressed: _busy ? null : _createTopic,
          icon: Icon(Icons.add_rounded, color: c.muted, size: 22),
        ),
        const SizedBox(width: 6),
      ],
    ),
  );

  Widget _topicPill(AidaColors c, Map<String, dynamic> topic) {
    final selected = topic['id'] == _topicId;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        selected: selected,
        button: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: ShapeDecoration(
            color: selected ? c.accentSoft : Colors.transparent,
            shape: StadiumBorder(
              side: BorderSide(color: selected ? Colors.transparent : c.border),
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: _busy || selected
                ? null
                : () => _switchTopic(topic['id'] as String),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Center(
                child: Text(
                  topic['name'] as String,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? c.accent : c.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyChat(AidaColors c, String topicName) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _topicId == 'general'
                  ? Icons.chat_bubble_outline_rounded
                  : Icons.auto_awesome_outlined,
              size: 30,
              color: c.accent,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            _topicId == 'general'
                ? 'The little things belong here.'
                : 'Let’s talk $topicName.',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: serif, fontSize: 28, color: c.ink),
          ),
          const SizedBox(height: 10),
          Text(
            _topicId == 'general'
                ? 'A good morning. A passing thought.\nSomething that made you smile.'
                : 'A shared topic for your ideas, photos, and plans.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, height: 1.7),
          ),
        ],
      ),
    ),
  );

  static DateTime _sentAt(Map<String, dynamic> message) =>
      DateTime.fromMillisecondsSinceEpoch(message['createdAt'] as int);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Consecutive messages from one person within a few minutes read as one
  /// thought, so their bubbles are grouped.
  static bool _joins(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['senderId'] == b['senderId'] &&
      _sameDay(_sentAt(a), _sentAt(b)) &&
      (b['createdAt'] as int) - (a['createdAt'] as int) < 3 * 60 * 1000;

  void _startReply(Map<String, dynamic> message) {
    if (_editing != null) _cancelEdit();
    setState(() => _replyTo = message);
    _messageFocus.requestFocus();
  }

  void _replaceMessage(Map<String, dynamic> updated) {
    final index = _messages.indexWhere((m) => m['id'] == updated['id']);
    if (index >= 0 && mounted) setState(() => _messages[index] = updated);
  }

  String get _myId => (_state!['user'] as Map)['id'] as String;

  /// Applies the change on screen at once; the server's copy replaces it, or
  /// the original comes back if the request fails.
  Future<void> _optimistic(
    Map<String, dynamic> original,
    Map<String, dynamic> local,
    Future<Map<String, dynamic>> Function() request,
  ) async {
    _replaceMessage(local);
    if (_preview) return;
    try {
      _replaceMessage(await request());
    } catch (error) {
      _replaceMessage(original);
      _showError(error);
    }
  }

  Future<void> _react(Map<String, dynamic> message, String emoji) {
    final reactions = ((message['reactions'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final current = reactions
        .where((r) => r['userId'] == _myId)
        .firstOrNull?['emoji'];
    final next = current == emoji ? null : emoji;
    HapticFeedback.selectionClick();
    return _optimistic(message, {
      ...message,
      'reactions': [
        ...reactions.where((r) => r['userId'] != _myId),
        if (next != null) {'userId': _myId, 'emoji': next},
      ],
    }, () => _api!.react(message['id'] as int, next));
  }

  Future<void> _toggleKeep(Map<String, dynamic> message) {
    final keep = message['kept'] != true;
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(keep ? 'Kept in Moments' : 'Removed from Moments'),
      ),
    );
    return _optimistic(message, {
      ...message,
      'kept': keep,
      'keptBy': keep ? _myId : null,
    }, () => _api!.keep(message['id'] as int, keep));
  }

  void _startEdit(Map<String, dynamic> message) {
    setState(() {
      if (_editing == null) _draftBeforeEdit = _messageController.text;
      _replyTo = null;
      _editing = message;
    });
    final text = message['text'] as String;
    _messageController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _messageFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _messageController.text = _draftBeforeEdit;
    _draftBeforeEdit = '';
  }

  Future<void> _saveEdit() => _run(() async {
    final editing = _editing!;
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (text != editing['text']) {
      _replaceMessage(
        _preview
            ? {
                ...editing,
                'text': text,
                'editedAt': DateTime.now().millisecondsSinceEpoch,
              }
            : await _api!.editMessage(editing['id'] as int, text),
      );
    }
    if (mounted && identical(_editing, editing)) _cancelEdit();
  });

  Future<void> _deleteMessage(Map<String, dynamic> message) async {
    final media = message['kind'] != 'text';
    final confirmed = await showDialog<bool>(
      context: _navigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        title: const Text('Delete for both of you?'),
        content: Text(
          media
              ? 'The ${message['kind'] == 'image' ? 'photo' : 'video'} is removed from both phones and your server. This can’t be undone.'
              : 'The message is removed from both phones. This can’t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: context.aida.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (identical(_replyTo, message)) setState(() => _replyTo = null);
    if (_editing?['id'] == message['id']) _cancelEdit();
    await _run(() async {
      _replaceMessage(
        _preview
            ? {
                ...message,
                'deleted': true,
                'text': null,
                'mediaId': null,
                'reactions': const [],
                'kept': false,
              }
            : await _api!.deleteMessage(message['id'] as int),
      );
    });
  }

  /// Downloads a photo or video into a private cache folder that is emptied
  /// each time, so shared or saved copies don't pile up inside Aida.
  Future<(File, String)> _downloadMedia(Map<String, dynamic> message) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/outgoing');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final mediaId = message['mediaId'] as String;
    final partial = File('${dir.path}/$mediaId');
    final type = await _api!.download(mediaId, partial);
    final extension = switch (type.split(';').first.trim()) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'video/webm' => 'webm',
      'video/quicktime' => 'mov',
      _ when type.startsWith('video/') => 'mp4',
      _ => 'jpg',
    };
    final file = await partial.rename('${dir.path}/aida-$mediaId.$extension');
    return (file, type);
  }

  Future<void> _saveToPhone(Map<String, dynamic> message) => _run(() async {
    if (!await Gal.hasAccess(toAlbum: true) &&
        !await Gal.requestAccess(toAlbum: true)) {
      throw const FormatException(
        'Allow Aida to save photos in Android settings.',
      );
    }
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Saving…')),
    );
    final (file, type) = await _downloadMedia(message);
    try {
      if (type.startsWith('video/')) {
        await Gal.putVideo(file.path, album: 'Aida');
      } else {
        await Gal.putImage(file.path, album: 'Aida');
      }
    } on GalException catch (error) {
      throw FormatException(switch (error.type) {
        GalExceptionType.accessDenied =>
          'Allow Aida to save photos in Android settings.',
        GalExceptionType.notEnoughSpace => 'Your phone is out of space.',
        GalExceptionType.notSupportedFormat =>
          'Your phone can’t save this format.',
        _ => 'Couldn’t save to your gallery.',
      });
    } finally {
      await file.delete().catchError((_) => file);
    }
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Saved to your gallery')));
  });

  Future<void> _share(Map<String, dynamic> message) async {
    if (message['kind'] == 'text') {
      await SharePlus.instance.share(
        ShareParams(text: message['text'] as String),
      );
      return;
    }
    await _run(() async {
      final (file, type) = await _downloadMedia(message);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: type)]),
      );
    });
  }

  Future<void> _messageOptions(
    Map<String, dynamic> message,
    String author,
    bool mine,
  ) async {
    HapticFeedback.mediumImpact();
    final kind = message['kind'];
    final sent = _sentAt(message);
    final time =
        '${sent.hour.toString().padLeft(2, '0')}:${sent.minute.toString().padLeft(2, '0')}';
    final myReaction = ((message['reactions'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((r) => r['userId'] == _myId)
        .firstOrNull?['emoji'];
    final choice = await showModalBottomSheet<String>(
      context: _navigatorKey.currentContext!,
      isScrollControlled: true,
      builder: (context) {
        final c = context.aida;
        Widget option(
          IconData icon,
          String label,
          String value, {
          Color? color,
        }) => ListTile(
          leading: Icon(icon, color: color ?? c.accent),
          title: Text(
            label,
            style: TextStyle(color: color ?? c.ink, fontSize: 15.5),
          ),
          visualDensity: VisualDensity.compact,
          onTap: () => Navigator.pop(context, value),
        );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final emoji in reactionChoices)
                        _ReactionChoice(
                          emoji: emoji,
                          selected: emoji == myReaction,
                          onTap: () => Navigator.pop(context, 'react:$emoji'),
                        ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$author · $time',
                        style: TextStyle(color: c.muted, fontSize: 12.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        messageSnippet(message),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.ink, fontSize: 15),
                      ),
                    ],
                  ),
                ),
                option(Icons.reply_rounded, 'Reply', 'reply'),
                if (kind == 'text')
                  option(Icons.copy_rounded, 'Copy text', 'copy'),
                if (kind == 'image')
                  option(Icons.open_in_full_rounded, 'View photo', 'view'),
                if (kind == 'video')
                  option(
                    Icons.play_circle_outline_rounded,
                    'Play video',
                    'view',
                  ),
                option(
                  message['kept'] == true
                      ? Icons.bookmark_remove_outlined
                      : Icons.bookmark_add_outlined,
                  message['kept'] == true
                      ? 'Remove from Moments'
                      : 'Keep in Moments',
                  'keep',
                ),
                if (kind != 'text')
                  option(Icons.download_rounded, 'Save to your phone', 'save'),
                option(Icons.ios_share_rounded, 'Share', 'share'),
                if (mine && kind == 'text')
                  option(Icons.edit_outlined, 'Edit', 'edit'),
                if (mine) ...[
                  const Divider(indent: 16, endIndent: 16),
                  option(
                    Icons.delete_outline_rounded,
                    'Delete for both of you',
                    'delete',
                    color: c.danger,
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    final navigator = _navigatorKey.currentContext;
    if (!mounted || navigator == null || !navigator.mounted || choice == null) {
      return;
    }
    if (choice.startsWith('react:')) {
      await _react(message, choice.substring(6));
      return;
    }
    switch (choice) {
      case 'reply':
        _startReply(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message['text'] as String));
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Copied')),
        );
      case 'view' when kind == 'image':
        openPhoto(navigator, _api!, message['mediaId'] as String);
      case 'view':
        openVideo(navigator, _api!, message['mediaId'] as String);
      case 'keep':
        await _toggleKeep(message);
      case 'save':
        await _saveToPhone(message);
      case 'share':
        await _share(message);
      case 'edit':
        _startEdit(message);
      case 'delete':
        await _deleteMessage(message);
    }
  }

  /// Scrolls to the quoted message (building older parts of the list as
  /// needed) and briefly highlights it.
  Future<void> _jumpTo(int id) async {
    if (!_messages.any((m) => m['id'] == id)) return;
    final key = _messageKeys.putIfAbsent(id, GlobalKey.new);
    for (var i = 0; i < 60 && key.currentContext == null; i++) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.pixels >= position.maxScrollExtent) break;
      _scrollController.jumpTo(
        (position.pixels + position.viewportDimension * .8).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    final target = key.currentContext;
    if (!mounted || target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      alignment: .4,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() => _highlightId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  Widget _composerBar(
    AidaColors c, {
    required IconData icon,
    required String title,
    required Map<String, dynamic> message,
    required String closeTooltip,
    required VoidCallback onClose,
  }) {
    final kindIcon = snippetIcon(message);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: c.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    if (kindIcon != null) ...[
                      Icon(kindIcon, size: 14, color: c.muted),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        messageSnippet(message),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.muted, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: closeTooltip,
            onPressed: onClose,
            icon: Icon(Icons.close_rounded, size: 20, color: c.muted),
          ),
        ],
      ),
    );
  }

  Widget _messageList(AidaColors c, String myId, String partnerName) =>
      ListView.builder(
        controller: _scrollController,
        // Reversed so the newest message stays put above the keyboard.
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        itemCount: _messages.length,
        findChildIndexCallback: (key) {
          final id = (key as ValueKey<int>).value;
          final index = _messages.indexWhere((m) => m['id'] == id);
          return index < 0 ? null : _messages.length - 1 - index;
        },
        itemBuilder: (context, position) {
          final index = _messages.length - 1 - position;
          final message = _messages[index];
          final id = message['id'] as int;
          final previous = index == 0 ? null : _messages[index - 1];
          final next = index == _messages.length - 1
              ? null
              : _messages[index + 1];
          final date = _sentAt(message);
          final newDay = previous == null || !_sameDay(_sentAt(previous), date);
          final mine = message['senderId'] == myId;
          final quoted = message['replyTo'] as Map<String, dynamic>?;
          final quotedId = message['replyToId'] as int?;
          return Column(
            key: ValueKey(id),
            children: [
              if (newDay) _dayLabel(c, date),
              MessageTile(
                key: _messageKeys.putIfAbsent(id, GlobalKey.new),
                message: message,
                mine: mine,
                api: _api!,
                highlighted: _highlightId == id,
                quoteAuthor: quoted?['senderId'] == myId ? 'You' : partnerName,
                onReply: () => _startReply(message),
                onOptions: () =>
                    _messageOptions(message, mine ? 'You' : partnerName, mine),
                onQuoteTap: quotedId == null ? null : () => _jumpTo(quotedId),
                receipt: id <= _partnerRead
                    ? 'Read'
                    : id <= _partnerDelivered
                    ? 'Delivered'
                    : 'Sent',
                joinsAbove: previous != null && _joins(previous, message),
                joinsBelow: next != null && _joins(message, next),
                animate: _freshIds.contains(id),
              ),
            ],
          );
        },
      );

  Widget _dayLabel(AidaColors c, DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final today = DateTime.now();
    final label = _sameDay(date, today)
        ? 'Today'
        : _sameDay(date, today.subtract(const Duration(days: 1)))
        ? 'Yesterday'
        : '${date.day} ${months[date.month - 1]}'
              '${date.year == today.year ? '' : ' ${date.year}'}';
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: c.surfaceMuted,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color: c.muted,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _composer(
    AidaColors c,
    String topicName,
    String myId,
    String partnerName,
  ) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: _editing != null
              ? _composerBar(
                  c,
                  icon: Icons.edit_outlined,
                  title: 'Editing message',
                  message: _editing!,
                  closeTooltip: 'Cancel edit',
                  onClose: _cancelEdit,
                )
              : _replyTo != null
              ? _composerBar(
                  c,
                  icon: Icons.reply_rounded,
                  title: _replyTo!['senderId'] == myId
                      ? 'Replying to yourself'
                      : 'Replying to $partnerName',
                  message: _replyTo!,
                  closeTooltip: 'Cancel reply',
                  onClose: () => setState(() => _replyTo = null),
                )
              : const SizedBox(width: double.infinity),
        ),
        if (_uploadLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: _uploadProgress,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _uploadLabel!,
                  style: TextStyle(color: c.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Attach',
                onPressed: _busy || _editing != null
                    ? null
                    : () => _attach(partnerName, topicName),
                icon: Icon(
                  Icons.add_circle_outline_rounded,
                  color: _editing != null ? c.border : c.accent,
                  size: 26,
                ),
              ),
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _messageController,
                  builder: (context, value, _) => TextField(
                    controller: _messageController,
                    focusNode: _messageFocus,
                    onChanged: _typingChanged,
                    maxLines: 5,
                    minLines: 1,
                    maxLength: 5000,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(color: c.ink, fontSize: 15.5, height: 1.4),
                    decoration: InputDecoration(
                      hintText: _topicId == 'general'
                          ? 'A little message…'
                          : 'Message in $topicName…',
                      counterText: '',
                      isDense: true,
                      contentPadding: const EdgeInsets.fromLTRB(18, 13, 6, 13),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      // The camera sits in the field until you start typing.
                      suffixIcon: value.text.isEmpty && _editing == null
                          ? _CameraButton(
                              color: c.muted,
                              enabled: !_busy,
                              onPhoto: () => _capture(video: false),
                              onVideo: () => _capture(video: true),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _messageController,
                builder: (context, value, _) {
                  final ready = value.text.trim().isNotEmpty;
                  final editing = _editing != null;
                  return AnimatedScale(
                    scale: ready ? 1 : .9,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutBack,
                    child: IconButton.filled(
                      tooltip: editing ? 'Save edit' : 'Send',
                      onPressed: _busy
                          ? null
                          : editing
                          ? _saveEdit
                          : _sendText,
                      style: IconButton.styleFrom(
                        fixedSize: const Size(46, 46),
                        backgroundColor: ready ? c.accent : c.accentSoft,
                        foregroundColor: ready ? c.onAccent : c.accent,
                        disabledBackgroundColor: c.accentSoft,
                      ),
                      icon: _busy && _uploadProgress == null
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.accent,
                              ),
                            )
                          : Icon(
                              editing
                                  ? Icons.check_rounded
                                  : Icons.arrow_upward_rounded,
                              size: 22,
                            ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _callBanner(AidaColors c, String myId) {
    final call = _call!;
    final incoming = call['initiatorId'] != myId;
    final active = call['state'] == 'active';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: c.hero,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(
            call['kind'] == 'video'
                ? Icons.videocam_rounded
                : Icons.call_rounded,
            color: c.warm,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              active
                  ? 'Call in progress'
                  : incoming
                  ? 'Incoming ${call['kind']} call'
                  : 'Calling…',
              style: TextStyle(color: c.onHero),
            ),
          ),
          if (active)
            TextButton(
              onPressed: _openCall,
              style: TextButton.styleFrom(foregroundColor: c.warm),
              child: const Text('Join'),
            )
          else if (incoming) ...[
            TextButton(
              onPressed: () => _callAction('decline'),
              style: TextButton.styleFrom(
                foregroundColor: c.onHero.withValues(alpha: .7),
              ),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => _callAction('accept'),
              style: FilledButton.styleFrom(
                backgroundColor: answerGreen,
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 40),
              ),
              child: const Text('Answer'),
            ),
          ] else
            TextButton(
              onPressed: () => _callAction('end'),
              style: TextButton.styleFrom(foregroundColor: c.warm),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }
}

class _ReactionChoice extends StatelessWidget {
  const _ReactionChoice({
    required this.emoji,
    required this.selected,
    required this.onTap,
  });
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    return Semantics(
      button: true,
      selected: selected,
      label: 'React $emoji',
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surfaceMuted,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? c.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

class _AttachTile extends StatelessWidget {
  const _AttachTile({
    required this.icon,
    required this.label,
    required this.caption,
    required this.tint,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String caption;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    return Material(
      color: c.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 10, 16),
          child: Column(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: .14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tint, size: 26),
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: TextStyle(
                  color: c.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(color: c.muted, fontSize: 11.5, height: 1.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tap for a photo, press and hold for a video.
class _CameraButton extends StatelessWidget {
  const _CameraButton({
    required this.color,
    required this.enabled,
    required this.onPhoto,
    required this.onVideo,
  });
  final Color color;
  final bool enabled;
  final VoidCallback onPhoto;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label: 'Take a photo',
    hint: 'Press and hold to record a video',
    excludeSemantics: true,
    child: InkResponse(
      onTap: enabled ? onPhoto : null,
      onLongPress: enabled
          ? () {
              HapticFeedback.mediumImpact();
              onVideo();
            }
          : null,
      radius: 22,
      child: Icon(Icons.photo_camera_outlined, color: color, size: 22),
    ),
  );
}
