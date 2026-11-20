import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:huangguo_vip/video_api.dart';

final _bases = [
  Uri.parse('https://primary.example.test'),
  Uri.parse('https://backup.example.test'),
];

Map<String, dynamic> _detail() => {
      'id': 42,
      'title': 'Example title',
      'cover': 'https://images.example.test/cover.jpg',
      'description': 'Example description',
      'tags': ['Example tag'],
      'score': '8.5',
      'total_episodes': 8,
      'episode_count': 3,
      'is_finished': 1,
      'episodes': [
        {'ep_num': 1, 'status': 1},
        {'ep_num': '3', 'status': '0'},
        {'ep_num': 8, 'status': 7},
      ],
    };

Map<String, dynamic> _playback() => {
      'id': 42,
      'ep': 3,
      'manifest_method': 'GET',
      'streams': {
        'main': 'https://media.example.test/play.m3u8?ticket=example-ticket',
      },
      'cdn': {
        'm3u8Enabled': true,
        'authKey': 'X-Example-Auth',
        'authValue': 'example-token',
        'app': 'example-app',
      },
    };

http.Response _success(Map<String, dynamic> data) => http.Response(
      jsonEncode({'status': 1, 'data': data}),
      200,
      headers: {'content-type': 'application/json'},
    );

TypeMatcher<VideoApiException> _error(VideoApiErrorKind kind) =>
    isA<VideoApiException>().having((error) => error.kind, 'kind', kind);

void main() {
  test('detail maps metadata and keeps actual episode numbers and statuses',
      () async {
    final api = VideoApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/videos/42');
        expect(request.headers['Accept'], 'application/json');
        return _success(_detail());
      }),
      baseUrls: _bases,
    );

    final detail = await api.fetchDetail(42);
    expect(detail.id, 42);
    expect(detail.title, 'Example title');
    expect(detail.cover, Uri.parse('https://images.example.test/cover.jpg'));
    expect(detail.description, 'Example description');
    expect(detail.tags, ['Example tag']);
    expect(detail.score, 8.5);
    expect(detail.totalEpisodes, 8);
    expect(detail.isFinished, isTrue);
    expect(detail.episodes.map((episode) => episode.number), [1, 3, 8]);
    expect(detail.episodes.map((episode) => episode.status), [1, 0, 7]);
    expect(() => detail.tags.add('change'), throwsUnsupportedError);
  });

  test('detail supports episode_count and empty episode lists', () async {
    final data = _detail()
      ..remove('total_episodes')
      ..remove('cover')
      ..remove('tags')
      ..remove('score')
      ..['episodes'] = []
      ..['is_finished'] = false;
    final api = VideoApi(
      client: MockClient((_) async => _success(data)),
      baseUrls: _bases,
    );
    final detail = await api.fetchDetail(42);
    expect(detail.totalEpisodes, 3);
    expect(detail.episodes, isEmpty);
    expect(detail.cover, isNull);
    expect(detail.tags, isEmpty);
    expect(detail.score, 0);
    expect(detail.isFinished, isFalse);
  });

  for (final failure in ['network', 'timeout', 'server']) {
    test('$failure failure falls back to the next configured origin', () async {
      final hosts = <String>[];
      final api = VideoApi(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          if (hosts.length == 1) {
            if (failure == 'network') {
              throw http.ClientException('sensitive network diagnostic');
            }
            if (failure == 'timeout') return Completer<http.Response>().future;
            return http.Response('server error', 503);
          }
          return _success(_detail());
        }),
        baseUrls: _bases,
        timeout: const Duration(milliseconds: 20),
      );
      expect((await api.fetchDetail(42)).id, 42);
      expect(hosts, ['primary.example.test', 'backup.example.test']);
    });
  }

  for (final status in [401, 403, 404, 429]) {
    test('HTTP $status stops without changing origins', () async {
      var requests = 0;
      final api = VideoApi(
        client: MockClient((_) async {
          requests++;
          return http.Response('private response body', status);
        }),
        baseUrls: _bases,
      );
      await expectLater(
        api.fetchDetail(42),
        throwsA(_error(status == 401 || status == 403
            ? VideoApiErrorKind.accessDenied
            : VideoApiErrorKind.http)),
      );
      expect(requests, 1);
    });
  }

  test('application denial never falls back or exposes server text', () async {
    var requests = 0;
    final api = VideoApi(
      client: MockClient((_) async {
        requests++;
        return http.Response(
          jsonEncode({'status': 0, 'message': 'example-secret'}),
          200,
        );
      }),
      baseUrls: _bases,
    );
    await expectLater(
      api.fetchPlayback(42, 3),
      throwsA(_error(VideoApiErrorKind.accessDenied).having(
        (error) => error.toString(),
        'safe description',
        isNot(contains('example-secret')),
      )),
    );
    expect(requests, 1);
  });

  for (final body in ['not JSON', '[]', '{}', '{"status":1,"data":[]}']) {
    test('malformed response is rejected without fallback: $body', () async {
      var requests = 0;
      final api = VideoApi(
        client: MockClient((_) async {
          requests++;
          return http.Response(body, 200);
        }),
        baseUrls: _bases,
      );
      await expectLater(api.fetchDetail(42),
          throwsA(_error(VideoApiErrorKind.invalidResponse)));
      expect(requests, 1);
    });
  }

  test('playback uses the POST response and preserves signed URI and headers',
      () async {
    final api = VideoApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/videos/42/episodes/3/playback');
        expect(request.headers['Content-Type'], 'application/json');
        expect(jsonDecode(request.body), isEmpty);
        return _success(_playback());
      }),
      baseUrls: _bases,
    );

    final playback = await api.fetchPlayback(42, 3);
    expect(playback.uri.toString(),
        'https://media.example.test/play.m3u8?ticket=example-ticket');
    expect(playback.httpHeaders, {
      'X-Example-Auth': 'example-token',
      'x-cdn-app': 'example-app',
    });
    expect(
        () => playback.httpHeaders['change'] = 'value', throwsUnsupportedError);
  });

  test('each playback request obtains fresh request-scoped credentials',
      () async {
    var requests = 0;
    final api = VideoApi(
      client: MockClient((_) async {
        final data = _playback();
        (data['cdn'] as Map)['authValue'] = 'example-token-${++requests}';
        return _success(data);
      }),
      baseUrls: _bases,
    );
    final first = await api.fetchPlayback(42, 3);
    final second = await api.fetchPlayback(42, 3);
    expect(first.httpHeaders['X-Example-Auth'], 'example-token-1');
    expect(second.httpHeaders['X-Example-Auth'], 'example-token-2');
  });

  for (final condition in ['disabled', 'not m3u8', 'no CDN']) {
    test('does not send CDN headers when $condition', () async {
      final data = _playback();
      if (condition == 'disabled') {
        (data['cdn'] as Map)['m3u8Enabled'] = false;
      } else if (condition == 'not m3u8') {
        (data['streams'] as Map)['main'] =
            'https://media.example.test/video.mp4';
      } else {
        data.remove('cdn');
      }
      final api = VideoApi(
        client: MockClient((_) async => _success(data)),
        baseUrls: _bases,
      );
      expect((await api.fetchPlayback(42, 3)).httpHeaders, isEmpty);
    });
  }

  final invalidPlayback = <String, void Function(Map<String, dynamic>)>{
    'wrong video': (data) => data['id'] = 43,
    'wrong episode': (data) => data['ep'] = 4,
    'unsupported method': (data) => data['manifest_method'] = 'POST',
    'invalid URI': (data) =>
        (data['streams'] as Map)['main'] = 'javascript:example',
    'relative URI': (data) => (data['streams'] as Map)['main'] = '/play.m3u8',
    'plaintext playback': (data) => (data['streams'] as Map)['main'] =
        'http://media.example.test/play.m3u8',
    'embedded credentials': (data) => (data['streams'] as Map)['main'] =
        'https://name:password@media.example.test/play.m3u8',
    'invalid header name': (data) =>
        (data['cdn'] as Map)['authKey'] = 'Invalid Header',
    'header injection': (data) =>
        (data['cdn'] as Map)['authValue'] = 'value\r\nX-Injected: value',
    'missing token': (data) => (data['cdn'] as Map).remove('authValue'),
  };
  for (final invalid in invalidPlayback.entries) {
    test('rejects ${invalid.key} without fallback', () async {
      var requests = 0;
      final data = _playback();
      invalid.value(data);
      final api = VideoApi(
        client: MockClient((_) async {
          requests++;
          return _success(data);
        }),
        baseUrls: _bases,
      );
      await expectLater(api.fetchPlayback(42, 3),
          throwsA(_error(VideoApiErrorKind.invalidResponse)));
      expect(requests, 1);
    });
  }

  test('rejects invalid detail episodes rather than manufacturing numbers',
      () async {
    final data = _detail()
      ..['episodes'] = [
        {'ep_num': 0, 'status': 1},
      ];
    final api = VideoApi(
      client: MockClient((_) async => _success(data)),
      baseUrls: _bases,
    );
    await expectLater(api.fetchDetail(42),
        throwsA(_error(VideoApiErrorKind.invalidResponse)));
  });

  test('exhausted network attempts report a sanitized error', () async {
    var requests = 0;
    final api = VideoApi(
      client: MockClient((_) async {
        requests++;
        throw http.ClientException('example-secret');
      }),
      baseUrls: _bases,
    );
    await expectLater(
      api.fetchDetail(42),
      throwsA(_error(VideoApiErrorKind.network).having(
        (error) => error.toString(),
        'safe description',
        isNot(contains('example-secret')),
      )),
    );
    expect(requests, 2);
  });

  test('validates IDs and episode numbers before sending any request',
      () async {
    var requests = 0;
    final api = VideoApi(
      client: MockClient((_) async {
        requests++;
        return _success(_detail());
      }),
      baseUrls: _bases,
    );
    await expectLater(api.fetchDetail(0), throwsArgumentError);
    await expectLater(api.fetchPlayback(-1, 1), throwsArgumentError);
    await expectLater(api.fetchPlayback(42, 0), throwsArgumentError);
    expect(requests, 0);
  });

  test('requires HTTP origins and a bounded positive timeout', () {
    final client = MockClient((_) async => _success(_detail()));
    expect(() => VideoApi(client: client, baseUrls: []), throwsArgumentError);
    expect(
        () =>
            VideoApi(client: client, baseUrls: [Uri.parse('file:///example')]),
        throwsArgumentError);
    expect(
        () =>
            VideoApi(client: client, baseUrls: _bases, timeout: Duration.zero),
        throwsArgumentError);
    expect(
        () => VideoApi(
              client: client,
              baseUrls: _bases,
              timeout: const Duration(minutes: 2),
            ),
        throwsArgumentError);
  });
}
