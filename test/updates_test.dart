import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aida/updates.dart';

Map<String, dynamic> _release({String tag = 'v2.3.0', bool checksum = true}) =>
    {
      'tag_name': tag,
      'body': 'Camera and more',
      'assets': [
        {
          'name': 'aida-${tag.substring(1)}.apk',
          'size': 4,
          'browser_download_url': 'https://example.test/aida.apk',
        },
        if (checksum)
          {
            'name': 'aida-${tag.substring(1)}.apk.sha256',
            'size': 82,
            'browser_download_url': 'https://example.test/aida.apk.sha256',
          },
      ],
    };

void main() {
  test('compares versions number by number', () {
    expect(AppUpdater.isNewer('2.3.0', '2.2.0'), isTrue);
    expect(AppUpdater.isNewer('2.10.0', '2.9.9'), isTrue);
    expect(AppUpdater.isNewer('3.0', '2.99.1'), isTrue);
    expect(AppUpdater.isNewer('2.2.0', '2.2.0'), isFalse);
    expect(AppUpdater.isNewer('2.1.9', '2.2.0'), isFalse);
    expect(AppUpdater.isNewer('2.2.0+7', '2.2.0'), isFalse);
  });

  test('reads the APK and its checksum from a GitHub release', () {
    final release = AppUpdater.parseRelease(_release())!;
    expect(release.version, '2.3.0');
    expect(release.apk.toString(), 'https://example.test/aida.apk');
    expect(release.checksum.toString(), 'https://example.test/aida.apk.sha256');
    expect(release.size, 4);
    expect(
      AppUpdater.parseRelease({'tag_name': 'v2.3.0', 'assets': []}),
      isNull,
    );
  });

  test('asks GitHub for the latest release of this repository', () async {
    late Uri asked;
    final updater = AppUpdater(
      client: MockClient((request) async {
        asked = request.url;
        return http.Response(jsonEncode(_release()), 200);
      }),
    );
    expect((await updater.latest())!.version, '2.3.0');
    expect(asked.path, '/repos/ypatodkar/aida/releases/latest');
  });

  group('download', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('aida-update-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    AppUpdater serving(List<int> apk, String sum) => AppUpdater(
      client: MockClient(
        (request) async => request.url.path.endsWith('.sha256')
            ? http.Response('$sum  aida-2.3.0.apk\n', 200)
            : http.Response.bytes(apk, 200),
      ),
    );

    test('keeps a file whose checksum matches', () async {
      final apk = [1, 2, 3, 4];
      final updater = serving(apk, sha256.convert(apk).toString());
      final progress = <double>[];
      final file = await updater.download(
        AppUpdater.parseRelease(_release())!,
        dir,
        onProgress: progress.add,
      );
      expect(await file.readAsBytes(), apk);
      expect(progress.last, 1);
    });

    test('refuses a file whose checksum does not match', () async {
      final updater = serving([1, 2, 3, 4], sha256.convert([9]).toString());
      await expectLater(
        updater.download(AppUpdater.parseRelease(_release())!, dir),
        throwsA(isA<UpdateException>()),
      );
      expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });
}
