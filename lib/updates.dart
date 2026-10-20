import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A published version of Aida: its APK and, when present, the SHA-256
/// file published next to it.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.apk,
    required this.size,
    this.checksum,
    this.notes = '',
  });

  final String version;
  final Uri apk;
  final int size;
  final Uri? checksum;
  final String notes;
}

/// Finds new versions on the project's GitHub releases, downloads them, and
/// hands them to Android's installer. Android always asks the person to
/// confirm, and only accepts an APK signed with the same key as this app.
class AppUpdater {
  AppUpdater({http.Client? client, this.repository = 'ypatodkar/aida'})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String repository;
  static const _channel = MethodChannel('aida/update');

  /// The running app's version name, such as "2.3.0".
  Future<String> currentVersion() async {
    final info = await _channel.invokeMapMethod<String, Object?>('version');
    return info?['name'] as String? ?? '0';
  }

  /// True when [candidate] is a later version than [current]; build
  /// suffixes such as "+7" are ignored.
  static bool isNewer(String candidate, String current) {
    List<int> parts(String version) => version
        .split('+')
        .first
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final a = parts(candidate);
    final b = parts(current);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static AppRelease? parseRelease(Map<String, dynamic> json) {
    final assets = ((json['assets'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    Map<String, dynamic>? asset(String suffix) => assets
        .where((a) => (a['name'] as String? ?? '').endsWith(suffix))
        .firstOrNull;
    final apk = asset('.apk');
    final sum = asset('.apk.sha256');
    final tag = json['tag_name'] as String? ?? '';
    if (apk == null || tag.isEmpty) return null;
    return AppRelease(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      apk: Uri.parse(apk['browser_download_url'] as String),
      size: apk['size'] as int? ?? 0,
      checksum: sum == null
          ? null
          : Uri.parse(sum['browser_download_url'] as String),
      notes: json['body'] as String? ?? '',
    );
  }

  Future<AppRelease?> latest() async {
    final response = await _client
        .get(
          Uri.https('api.github.com', '/repos/$repository/releases/latest'),
          headers: {'accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw const UpdateException(
        'Couldn’t check for updates. Try again later.',
      );
    }
    return parseRelease(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Downloads [release] into [folder]/updates and checks it against the
  /// published SHA-256 before returning it.
  Future<File> download(
    AppRelease release,
    Directory folder, {
    void Function(double fraction)? onProgress,
  }) async {
    final dir = Directory('${folder.path}/updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}/aida-${release.version}.apk');
    try {
      String? expected;
      if (release.checksum != null) {
        final sum = await _client.get(release.checksum!);
        if (sum.statusCode != 200) {
          throw const UpdateException('Couldn’t verify the update.');
        }
        expected = sum.body.trim().split(RegExp(r'\s+')).first.toLowerCase();
      }
      final response = await _client.send(http.Request('GET', release.apk));
      if (response.statusCode != 200) {
        throw const UpdateException('The download didn’t start. Try again.');
      }
      final total = response.contentLength ?? release.size;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      onProgress?.call(1);
      if (expected != null) {
        final actual = (await sha256.bind(file.openRead()).first).toString();
        if (actual != expected) {
          throw const UpdateException(
            'The download was damaged, so it wasn’t installed. Try again.',
          );
        }
      }
      return file;
    } catch (_) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }

  /// Whether Android lets Aida open the installer. The first time, the
  /// person allows it once in Settings.
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  Future<void> allowInstalls() => _channel.invokeMethod('allowInstalls');

  Future<void> install(File apk) =>
      _channel.invokeMethod('install', {'path': apk.path});
}
