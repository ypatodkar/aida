import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import 'api.dart';
import 'call_screen.dart';
import 'media_view.dart';
import 'design.dart';
import 'notifications.dart';

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
    if (kDebugMode && const bool.fromEnvironment('AIDA_DESIGN_PREVIEW')) {
      _api = AidaApi('https://preview.invalid', token: 'preview-only');
      _state = {
        'user': {'id': 'me', 'name': 'Yash'},
        'pair': {
          'id': 'preview',
          'partner': {'id': 'them', 'name': 'Sofia', 'online': true},
        },
      };
      _liveReady = true;
      _partnerRead = 3;
      _partnerDelivered = 3;
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
        },
        {
          'id': 3,
          'senderId': 'me',
          'kind': 'text',
          'text': 'Already my favorite place. Just because you’re there.',
          'createdAt': DateTime.now().millisecondsSinceEpoch - 60000,
        },
        {
          'id': 4,
          'senderId': 'them',
          'kind': 'text',
          'text': 'Let’s put it in our Italy plans ✨',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
      ];
      setState(() => _loading = false);
      return;
    }
    await _notifications.initialize();
    _notifications.onTap = _handleNotice;
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

  void _ackVisibleMessages() {
    if (kDebugMode && const bool.fromEnvironment('AIDA_DESIGN_PREVIEW')) return;
    unawaited(_ackMessages());
  }

  Future<void> _ackMessages({bool allowRead = true}) async {
    final api = _api;
    final pairId = _loadedPairId;
    final topicId = _topicId;
    if (api?.token == null || pairId == null || _messages.isEmpty) return;
    final last = _messages.last['id'] as int;
    final atBottom =
        _scrollController.hasClients &&
        _scrollController.position.extentAfter < 40;
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
    if (read > oldRead) _readAcks[key] = read;
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
        _scrollController.position.extentAfter < 80;
    var cursor = _messages.isEmpty ? 0 : _messages.last['id'] as int;
    while (true) {
      final page = await api.messages(after: cursor, topicId: topicId);
      if (!mounted ||
          generation != _messageGeneration ||
          pairId != _loadedPairId) {
        return;
      }
      final items = (page['messages'] as List).cast<Map<String, dynamic>>();
      final receipt = page['partnerReceipt'] as Map<String, dynamic>?;
      if (receipt != null) setState(() => _applyReceipt(receipt));
      if (items.isNotEmpty && mounted) {
        final latest = _messages.isEmpty ? 0 : _messages.last['id'] as int;
        setState(
          () => _messages.addAll(
            items.where((item) => (item['id'] as int) > latest),
          ),
        );
        cursor = items.last['id'] as int;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              generation == _messageGeneration &&
              followLatest &&
              _scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
      if (page['hasMore'] != true || items.isEmpty) break;
    }
    // Delivery is independent of rendering; a background sync is not a read.
    await _ackMessages(allowRead: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _messageGeneration) _ackVisibleMessages();
    });
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
              event['messageId'] != null) {
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
    });
  }

  Future<void> _sendText() => _run(() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _stopTyping();
    _messageController.clear();
    try {
      await _api!.sendMessage(
        text,
        _uuid.v4(),
        topicId: _topicId,
        pairId: _loadedPairId,
      );
      await _loadMessages();
    } catch (_) {
      _messageController.text = text;
      rethrow;
    }
  });

  Future<void> _pickAndUpload(bool video) => _run(() async {
    final uploadPair = _loadedPairId;
    final uploadTopic = _topicId;
    final picked = video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    final size = await file.length();
    if (size > 100 * 1024 * 1024) {
      throw const FormatException('Choose a file under 100 MB');
    }
    var mime = picked.mimeType;
    if (mime == null || mime.isEmpty) {
      final extension = picked.name.toLowerCase().split('.').last;
      mime = switch (extension) {
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
    if (mime.isEmpty) throw const FormatException('Unsupported image or video');
    setState(() => _uploadProgress = 0);
    try {
      await _api!.upload(
        file,
        mime,
        topicId: uploadTopic,
        pairId: uploadPair,
        onProgress: (fraction) {
          if (mounted) setState(() => _uploadProgress = fraction);
        },
      );
      await _loadMessages();
    } finally {
      if (mounted) setState(() => _uploadProgress = null);
    }
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aida',
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      theme: aidaTheme(),
      home: Builder(
        builder: (context) => _loading
            ? const Scaffold(body: Center(child: AidaMark()))
            : _api?.token == null
            ? _authScreen(context)
            : _state == null
            ? _connectionScreen()
            : _state?['pair'] == null
            ? _unpairedScreen(context)
            : _chatScreen(context),
      ),
    );
  }

  Widget _authScreen(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
            children: [
              Row(
                children: [
                  const Text(
                    'aida',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 32,
                      color: ink,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Server settings',
                    onPressed: _serverSettings,
                    icon: const Icon(Icons.tune_rounded, size: 21),
                  ),
                ],
              ),
              const SizedBox(height: 54),
              Container(
                height: 230,
                decoration: BoxDecoration(
                  color: sage,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: const Center(child: AidaMark(size: 140)),
              ),
              const SizedBox(height: 40),
              const Text(
                'A LITTLE CLOSER',
                style: TextStyle(
                  letterSpacing: 3,
                  fontSize: 10,
                  color: muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Your person.\nYour little world.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 18),
              const Text(
                'The everyday stories, the big plans, and the calls that make the distance feel smaller.',
                style: TextStyle(color: muted, fontSize: 16, height: 1.6),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _busy ? null : _googleSignIn,
                icon: const Icon(Icons.account_circle_outlined),
                label: Text(_busy ? 'Signing in…' : 'Continue with Google'),
              ),
              const SizedBox(height: 18),
              const Text(
                'One connection. A space just for you two.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted, fontSize: 12),
              ),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    _problem!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFAD5144)),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _connectionScreen() {
    return Scaffold(
      appBar: AppBar(title: const Text('Aida')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 56),
              const SizedBox(height: 16),
              Text(
                _problem ?? 'Connecting to your server…',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _refresh, child: const Text('Retry')),
              TextButton(
                onPressed: _serverSettings,
                child: const Text('Change server address'),
              ),
              TextButton(onPressed: _signOut, child: const Text('Sign out')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unpairedScreen(BuildContext context) {
    final user = (_state?['user'] as Map<String, dynamic>?) ?? {};
    final code = (_state?['invite'] as Map?)?['code']?.toString();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'aida',
          style: TextStyle(fontFamily: 'serif', fontSize: 30),
        ),
        actions: [_accountMenu()],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 24),
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
              const Text(
                'Invite your person into a shared space for conversations, plans, and being together.',
                style: TextStyle(color: muted, height: 1.6),
              ),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.link_rounded, color: gold, size: 32),
                    const SizedBox(height: 18),
                    Text(
                      code == null
                          ? 'It starts with an invitation.'
                          : 'Your invitation is ready.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'serif',
                        color: cream,
                        fontSize: 25,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (code == null) ...[
                      const Text(
                        'Only the person who accepts your code can join you.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _busy ? null : _createInvite,
                        style: FilledButton.styleFrom(
                          backgroundColor: gold,
                          foregroundColor: ink,
                        ),
                        child: const Text('Create invite'),
                      ),
                    ] else ...[
                      SelectableText(
                        code,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          letterSpacing: 3,
                          fontSize: 25,
                          color: gold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'One use · Expires in 24 hours',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, fontSize: 12),
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
                            icon: const Icon(Icons.copy_rounded, color: cream),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: gold,
                              foregroundColor: ink,
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
                        child: const Text(
                          'Revoke invite',
                          style: TextStyle(color: Colors.white60),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Already have an invite?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _inviteController,
                textCapitalization: TextCapitalization.characters,
                maxLength: 10,
                decoration: const InputDecoration(
                  hintText: 'Enter their code',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _acceptInvite,
                child: const Text('Review invitation'),
              ),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    _problem!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accountMenu({bool paired = false}) => PopupMenuButton<String>(
    tooltip: 'Your account',
    icon: const Icon(Icons.more_horiz_rounded),
    onSelected: (value) {
      if (value == 'name') _changeName();
      if (value == 'signout') _signOut();
      if (value == 'disconnect') _disconnect();
      if (value == 'server') _serverSettings();
      if (value == 'notifications') {
        _run(() async {
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
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'name', child: Text('Your name')),
      const PopupMenuItem(
        value: 'notifications',
        child: Text('Enable notifications'),
      ),
      if (paired)
        const PopupMenuItem(
          value: 'disconnect',
          child: Text('Disconnect and delete'),
        ),
      const PopupMenuItem(value: 'server', child: Text('Server settings')),
      const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      const PopupMenuItem(enabled: false, child: Text('Aida 2.0.1')),
    ],
  );

  Widget _chatScreen(BuildContext context) {
    final pair = _state!['pair'] as Map<String, dynamic>;
    final partner = pair['partner'] as Map<String, dynamic>;
    final user = _state!['user'] as Map<String, dynamic>;
    final topicName =
        _topics.firstWhere(
              (t) => t['id'] == _topicId,
              orElse: () => {'name': 'Everyday'},
            )['name']
            as String;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 86,
        titleSpacing: 20,
        title: Row(
          children: [
            PersonAvatar(partner['name'] as String),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    partner['name'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 6,
                        color: _liveReady && partner['online'] == true
                            ? const Color(0xFF46956A)
                            : muted,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _presenceLabel(partner),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
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
          _accountMenu(paired: true),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE4E7DD))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _topics.map((topic) {
                        final selected = topic['id'] == _topicId;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            selected: selected,
                            showCheckmark: false,
                            selectedColor: ink,
                            backgroundColor: Colors.white,
                            side: BorderSide(
                              color: selected ? ink : const Color(0xFFE1E5DB),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            label: Text(
                              topic['name'] as String,
                              style: TextStyle(
                                color: selected ? cream : muted,
                                fontSize: 12,
                              ),
                            ),
                            onSelected: _busy
                                ? null
                                : (_) => _switchTopic(topic['id'] as String),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Create shared topic',
                  onPressed: _busy ? null : _createTopic,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
          if (_call != null) _callBanner(user['id'] as String),
          if (_problem != null)
            MaterialBanner(
              content: Text(_problem!),
              actions: [
                TextButton(onPressed: _refresh, child: const Text('Retry')),
              ],
            ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(36),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: const BoxDecoration(
                              color: sage,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _topicId == 'general'
                                  ? Icons.chat_bubble_outline_rounded
                                  : Icons.auto_awesome_outlined,
                              size: 32,
                              color: ink,
                            ),
                          ),
                          const SizedBox(height: 22),
                          Text(
                            _topicId == 'general'
                                ? 'The little things belong here.'
                                : 'Let’s talk $topicName.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'serif',
                              fontSize: 25,
                              color: ink,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _topicId == 'general'
                                ? 'A good morning. A passing thought.\nSomething that made you smile.'
                                : 'A shared topic for your ideas, photos, and plans.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: muted, height: 1.7),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final date = DateTime.fromMillisecondsSinceEpoch(
                        message['createdAt'] as int,
                      );
                      final previous = index == 0
                          ? null
                          : DateTime.fromMillisecondsSinceEpoch(
                              _messages[index - 1]['createdAt'] as int,
                            );
                      final newDay =
                          previous == null ||
                          date.year != previous.year ||
                          date.month != previous.month ||
                          date.day != previous.day;
                      final today = DateTime.now();
                      final dayLabel =
                          date.year == today.year &&
                              date.month == today.month &&
                              date.day == today.day
                          ? 'TODAY'
                          : '${date.day} ${const ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'][date.month - 1]} ${date.year}';
                      return Column(
                        children: [
                          if (newDay)
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 4,
                                bottom: 22,
                              ),
                              child: Text(
                                dayLabel,
                                style: const TextStyle(
                                  fontSize: 9,
                                  letterSpacing: 2,
                                  color: muted,
                                ),
                              ),
                            ),
                          MessageTile(
                            message: message,
                            mine: message['senderId'] == user['id'],
                            api: _api!,
                            receipt: (message['id'] as int) <= _partnerRead
                                ? 'Read'
                                : (message['id'] as int) <= _partnerDelivered
                                ? 'Delivered'
                                : 'Sent',
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (_uploadProgress != null)
            LinearProgressIndicator(
              value: _uploadProgress,
              color: ink,
              backgroundColor: sage,
            ),
          if (_partnerTyping)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '${partner['name']} is typing…',
                    style: const TextStyle(
                      color: muted,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            ),
          Container(
            decoration: const BoxDecoration(
              color: cream,
              border: Border(top: BorderSide(color: Color(0xFFE4E7DD))),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 12, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PopupMenuButton<String>(
                      enabled: !_busy,
                      tooltip: 'Attach photo or video',
                      onSelected: (value) => _pickAndUpload(value == 'video'),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'image', child: Text('Photo')),
                        PopupMenuItem(value: 'video', child: Text('Video')),
                      ],
                      icon: const Icon(Icons.add_rounded, color: ink),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocus,
                        onChanged: _typingChanged,
                        maxLines: 5,
                        minLines: 1,
                        maxLength: 5000,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: _topicId == 'general'
                              ? 'A little message…'
                              : 'Message in $topicName…',
                          counterText: '',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filled(
                      tooltip: 'Send',
                      onPressed: _busy ? null : _sendText,
                      style: IconButton.styleFrom(
                        fixedSize: const Size(48, 48),
                        backgroundColor: ink,
                      ),
                      icon: _busy && _uploadProgress == null
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: cream,
                              ),
                            )
                          : const Icon(Icons.arrow_upward_rounded, size: 22),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _callBanner(String myId) {
    final call = _call!;
    final incoming = call['initiatorId'] != myId;
    final active = call['state'] == 'active';
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(call['kind'] == 'video' ? Icons.videocam : Icons.call),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                active
                    ? 'Call in progress'
                    : incoming
                    ? 'Incoming ${call['kind']} call'
                    : 'Calling…',
              ),
            ),
            if (active)
              TextButton(onPressed: _openCall, child: const Text('Join'))
            else if (incoming) ...[
              TextButton(
                onPressed: () => _callAction('decline'),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => _callAction('accept'),
                child: const Text('Answer'),
              ),
            ] else
              TextButton(
                onPressed: () => _callAction('end'),
                child: const Text('Cancel'),
              ),
          ],
        ),
      ),
    );
  }
}
