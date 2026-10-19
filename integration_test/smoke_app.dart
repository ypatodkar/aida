// Test-only entrypoint. Never used by the production APK build.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:aida/main.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  const token = String.fromEnvironment('AIDA_TEST_TOKEN');
  if (token.isEmpty) throw StateError('A local fixture token is required');
  await storage.write(key: 'api_url', value: 'http://10.0.2.2:18990');
  await storage.write(key: 'session_token', value: token);
  runApp(const AidaApp());
}
