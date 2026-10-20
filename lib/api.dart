import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

class ApiException implements Exception {
  ApiException(this.message, this.status);

  final String message;
  final int status;

  @override
  String toString() => message;
}

class AidaApi {
  AidaApi(this.baseUrl, {this.token});

  final String baseUrl;
  String? token;
  final http.Client _client = http.Client();

  Uri _uri(String path) => Uri.parse(baseUrl).resolve(path);

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, _uri(path));
    request.headers['accept'] = 'application/json';
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 15)),
    );
    Map<String, dynamic> value;
    try {
      value = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(
        'Server returned an invalid response',
        response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        value['message']?.toString() ?? 'Request failed',
        response.statusCode,
      );
    }
    return value;
  }

  Future<Map<String, dynamic>> signInWithGoogle(String idToken) =>
      _request('POST', '/v1/auth/google', body: {'idToken': idToken});

  Future<Map<String, dynamic>> me() => _request('GET', '/v1/me');

  Future<Map<String, dynamic>> setName(String name) =>
      _request('PATCH', '/v1/me', body: {'name': name});

  Future<Map<String, dynamic>> createInvite() =>
      _request('POST', '/v1/invites');

  Future<Map<String, dynamic>> lookupInvite(String code) =>
      _request('GET', '/v1/invites/${Uri.encodeComponent(code)}');

  Future<Map<String, dynamic>> acceptInvite(String code) =>
      _request('POST', '/v1/invites/accept', body: {'code': code});

  Future<void> revokeInvite() async {
    await _request('DELETE', '/v1/invites');
  }

  Future<void> disconnect() async {
    await _request('DELETE', '/v1/pair');
  }

  Future<Map<String, dynamic>> topics() => _request('GET', '/v1/topics');

  Future<Map<String, dynamic>> createTopic(String name, String pairId) =>
      _request('POST', '/v1/topics', body: {'name': name, 'pairId': pairId});

  Future<Map<String, dynamic>> registerDevice(String deviceToken) =>
      _request('POST', '/v1/devices', body: {'token': deviceToken});

  Future<Map<String, dynamic>> message(String id) =>
      _request('GET', '/v1/messages/$id');

  /// A null [topicId] returns messages from every topic.
  Future<Map<String, dynamic>> messages({
    int after = 0,
    String? topicId = 'general',
  }) => _request(
    'GET',
    topicId == null
        ? '/v1/messages?after=$after'
        : '/v1/messages?after=$after&topicId=${Uri.encodeComponent(topicId)}',
  );

  Future<Map<String, dynamic>> sendMessage(
    String text,
    String clientId, {
    String topicId = 'general',
    String? pairId,
    int? replyToId,
  }) => _request(
    'POST',
    '/v1/messages',
    body: {
      'text': text,
      'clientId': clientId,
      'topicId': topicId,
      'pairId': ?pairId,
      'replyToId': ?replyToId,
    },
  );

  Future<void> acknowledgeMessages({
    required String pairId,
    required String topicId,
    required int deliveredThrough,
    required int readThrough,
  }) async {
    await _request(
      'POST',
      '/v1/receipts',
      body: {
        'pairId': pairId,
        'topicId': topicId,
        'deliveredThrough': deliveredThrough,
        'readThrough': readThrough,
      },
    );
  }

  Future<Map<String, dynamic>> upload(
    File file,
    String mime, {
    String topicId = 'general',
    String? pairId,
    int? replyToId,
    void Function(double fraction)? onProgress,
  }) async {
    final length = await file.length();
    final request = http.StreamedRequest('POST', _uri('/v1/media'));
    request.contentLength = length;
    request.headers['content-type'] = mime;
    request.headers['x-topic-id'] = topicId;
    if (pairId != null) request.headers['x-pair-id'] = pairId;
    if (replyToId != null) request.headers['x-reply-to-id'] = '$replyToId';
    request.headers['x-file-name'] = file.uri.pathSegments.last;
    request.headers['authorization'] = 'Bearer $token';
    final responseFuture = _client.send(request);
    var sent = 0;
    await for (final chunk in file.openRead()) {
      request.sink.add(chunk);
      sent += chunk.length;
      onProgress?.call(sent / length);
    }
    await request.sink.close();
    final response = await http.Response.fromStream(await responseFuture);
    final value = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        value['message']?.toString() ?? 'Upload failed',
        response.statusCode,
      );
    }
    return value;
  }

  /// Messages in [topicId] that changed (edits, deletions, reactions, keeps)
  /// after change number [since].
  Future<Map<String, dynamic>> changes({
    required int since,
    required String topicId,
  }) => _request(
    'GET',
    '/v1/messages/changes?since=$since&topicId=${Uri.encodeComponent(topicId)}',
  );

  Future<Map<String, dynamic>> editMessage(int id, String text) =>
      _request('PATCH', '/v1/messages/$id', body: {'text': text});

  Future<Map<String, dynamic>> deleteMessage(int id) =>
      _request('DELETE', '/v1/messages/$id');

  /// Sets this person's reaction, or clears it when [emoji] is null.
  Future<Map<String, dynamic>> react(int id, String? emoji) => emoji == null
      ? _request('DELETE', '/v1/messages/$id/reaction')
      : _request('PUT', '/v1/messages/$id/reaction', body: {'emoji': emoji});

  Future<Map<String, dynamic>> keep(int id, bool keep) =>
      _request(keep ? 'PUT' : 'DELETE', '/v1/messages/$id/keep');

  Future<Map<String, dynamic>> kept() => _request('GET', '/v1/kept');

  /// Saves a photo or video to [file] and returns its content type.
  Future<String> download(String mediaId, File file) async {
    final request = http.Request('GET', mediaUrl(mediaId))
      ..headers.addAll(mediaHeaders);
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw ApiException(
        'That photo or video is unavailable',
        response.statusCode,
      );
    }
    await response.stream.pipe(file.openWrite());
    return response.headers['content-type'] ?? 'application/octet-stream';
  }

  /// What you call your partner; an empty string clears it.
  Future<Map<String, dynamic>> setNickname(String nickname) =>
      _request('PUT', '/v1/pair/nickname', body: {'nickname': nickname});

  Future<Map<String, dynamic>> setPhoto(File file, String mime) async {
    final request = http.Request('PUT', _uri('/v1/me/photo'))
      ..headers['content-type'] = mime
      ..headers['authorization'] = 'Bearer $token'
      ..bodyBytes = await file.readAsBytes();
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 30)),
    );
    final value = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw ApiException(
        value['message']?.toString() ?? 'Photo upload failed',
        response.statusCode,
      );
    }
    return value;
  }

  Future<Map<String, dynamic>> deletePhoto() =>
      _request('DELETE', '/v1/me/photo');

  /// [version] is the photo's `photoAt`, so a new photo is never served from
  /// the image cache.
  Uri userPhotoUrl(String userId, int version) =>
      _uri('/v1/users/$userId/photo?v=$version');

  /// Messages after your read point in [topicId], for notifications.
  Future<Map<String, dynamic>> unread(String topicId) =>
      _request('GET', '/v1/unread?topicId=${Uri.encodeComponent(topicId)}');

  Future<List<int>?> photoBytes(String userId, int version) async {
    final response = await _client
        .get(userPhotoUrl(userId, version), headers: mediaHeaders)
        .timeout(const Duration(seconds: 10));
    return response.statusCode == 200 ? response.bodyBytes : null;
  }

  Uri mediaUrl(String id) => _uri('/v1/media/$id');

  Map<String, String> get mediaHeaders => {'authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> currentCall() =>
      _request('GET', '/v1/calls/current');

  Future<Map<String, dynamic>> startCall(String kind) =>
      _request('POST', '/v1/calls', body: {'kind': kind});

  Future<void> callAction(String id, String action) async {
    await _request('POST', '/v1/calls/$id/$action');
  }

  Future<Map<String, dynamic>> joinCall(String id) =>
      _request('POST', '/v1/calls/$id/join');

  Future<void> signOut() async {
    await _request('POST', '/v1/auth/signout');
  }

  IOWebSocketChannel live() {
    final uri = _uri('/v1/live');
    final wsUri = uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
    return IOWebSocketChannel.connect(
      wsUri,
      headers: {'authorization': 'Bearer $token'},
      pingInterval: const Duration(seconds: 25),
    );
  }

  void close() => _client.close();
}
