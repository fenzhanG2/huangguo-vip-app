import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:huangguo_vip/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

http.Response _jsonResponse(Object data) => http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _listResponse(int page, {int pages = 2}) => _jsonResponse({
      'status': 1,
      'data': {
        'items': [
          {
            'id': page,
            'title': 'Drama $page',
            'cover': 'https://example.test/cover.png',
            'score': 8.5,
            'episode_count': 10,
            'is_finished': true,
          },
        ],
        'pagination': {'page': page, 'pages': pages},
      },
    });

http.Response _detailResponse({List<int> episodes = const [1, 3]}) =>
    _jsonResponse({
      'status': 1,
      'data': {
        'id': 1,
        'title': 'Example drama',
        'cover': null,
        'description': 'A fictional test fixture.',
        'tags': ['Example'],
        'score': 8.5,
        'total_episodes': 3,
        'is_finished': false,
        'episodes': [
          for (final episode in episodes) {'ep_num': episode, 'status': 1},
        ],
      },
    });

http.Response _playbackResponse({String ticket = 'ticket1', int episode = 1}) =>
    _jsonResponse({
      'status': 1,
      'data': {
        'id': '1',
        'ep': episode,
        'manifest_method': 'GET',
        'streams': {'main': 'https://example.test/stream.m3u8?ticket=$ticket'},
        'cdn': {
          'm3u8Enabled': true,
          'otherEnabled': false,
          'authKey': 'x-test-auth',
          'authValue': ticket,
          'app': 'fixture',
        },
      },
    });

class _TestVideoController extends VideoPlayerController {
  final Future<void> Function() onInitialize;
  bool wasDisposed = false;
  int playCalls = 0;
  final calls = <String>[];

  _TestVideoController(this.onInitialize)
      : super.networkUrl(Uri.parse('https://example.test/video.mp4'));

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    await onInitialize();
    if (wasDisposed) return;
    value = const VideoPlayerValue(
      duration: Duration(minutes: 2),
      size: Size(720, 1280),
      isInitialized: true,
    );
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playCalls++;
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek:${position.inSeconds}');
    value = value.copyWith(position: position);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> dispose() async {
    wasDisposed = true;
    await super.dispose();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('app starts with a consistent dark theme', (tester) async {
    await tester.pumpWidget(HuangguoVIPApp(
      client: MockClient((_) async => _listResponse(1, pages: 1)),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Drama 1'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets(
      'failed pagination retries the same page and retains earlier items',
      (tester) async {
    final requestedPages = <int>[];
    var failedPageTwoRequests = 0;
    final client = MockClient((request) async {
      final page = int.parse(request.url.queryParameters['page']!);
      requestedPages.add(page);
      if (page == 2 && failedPageTwoRequests++ < 2) {
        return http.Response('unavailable', 503);
      }
      return _listResponse(page);
    });
    await tester.pumpWidget(MaterialApp(home: HomePage(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(find.text('Drama 1'), findsOneWidget);
    expect(find.text('重试加载'), findsOneWidget);
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();

    expect(requestedPages, [1, 2, 2, 2]);
    expect(find.text('Drama 1'), findsOneWidget);
    expect(find.text('Drama 2'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter selection updates in the dialog and cancel discards it',
      (tester) async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return _listResponse(1, pages: 1);
    });
    await tester.pumpWidget(MaterialApp(home: HomePage(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新'));
    await tester.pump();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '最新')).selected,
      isTrue,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '热门')).selected,
      isTrue,
    );
    await tester.tap(find.text('已完结'));
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters,
        {'page': '1', 'sort': 'hot', 'is_finished': '1'});
  });

  testWidgets('detail failure ends loading and offers retry', (tester) async {
    final hosts = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: DetailPage(
        dramaId: 1,
        client: MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response('<html>Not found</html>', 404);
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(hosts, ['huangguoai.com']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('detail fallback displays actual nonconsecutive episode numbers',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DetailPage(
        dramaId: 1,
        client: MockClient((request) async {
          if (request.url.host == 'huangguoai.com') {
            return http.Response('unavailable', 503);
          }
          expect(request.url.path, '/api/videos/1');
          return _detailResponse();
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Example drama'), findsNWidgets(2));
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第3集'), findsOneWidget);
    expect(find.text('第2集'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail with no episodes shows an explicit empty state',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DetailPage(
        dramaId: 1,
        client: MockClient((_) async => _detailResponse(episodes: [])),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('暂未获取到可播放剧集'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('late detail response is ignored after leaving the page',
      (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
      home: DetailPage(
        dramaId: 1,
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
      ),
    ));
    await tester.pumpWidget(const SizedBox());
    response.complete(_detailResponse());
    await tester.pump();

    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing playback URL shows an error instead of a null crash',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 1,
        dramaTitle: 'Example drama',
        client: MockClient((_) async => _jsonResponse({
              'status': 1,
              'data': {'streams': {}},
            })),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('视频加载失败，请重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'video initialization failure is recoverable and disposes resources',
      (tester) async {
    final controller = _TestVideoController(() async {
      throw StateError('unavailable video');
    });
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 1,
        dramaTitle: 'Example drama',
        client: MockClient((_) async => _playbackResponse()),
        controllerFactory: (_, __) => controller,
      ),
    ));
    await tester.pumpAndSettle();

    expect(controller.wasDisposed, isTrue);
    expect(controller.playCalls, 0);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during video initialization prevents late playback',
      (tester) async {
    final initialization = Completer<void>();
    final controller = _TestVideoController(() => initialization.future);
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 1,
        dramaTitle: 'Example drama',
        client: MockClient((_) async => _playbackResponse()),
        controllerFactory: (_, __) => controller,
      ),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    initialization.complete();
    await tester.pump();

    expect(controller.wasDisposed, isTrue);
    expect(controller.playCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'playback restores progress before play and forwards fresh headers',
      (tester) async {
    SharedPreferences.setMockInitialValues({'progress_1_3': 35.0});
    final controller = _TestVideoController(() async {});
    Uri? receivedUri;
    Map<String, String>? receivedHeaders;
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 3,
        dramaTitle: 'Example drama',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/videos/1/episodes/3/playback');
          return _playbackResponse(episode: 3);
        }),
        controllerFactory: (uri, headers) {
          receivedUri = uri;
          receivedHeaders = headers;
          return controller;
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(controller.calls, ['initialize', 'seek:35', 'play']);
    expect(receivedUri?.queryParameters['ticket'], 'ticket1');
    expect(receivedHeaders, {'x-test-auth': 'ticket1', 'x-cdn-app': 'fixture'});
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys(),
        {'progress_1_3', 'last_drama_id', 'last_episode'});
  });

  testWidgets('retry requests new playback credentials instead of reusing them',
      (tester) async {
    var requests = 0;
    final credentials = <String>[];
    final controllers = <_TestVideoController>[];
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 1,
        dramaTitle: 'Example drama',
        client: MockClient((_) async {
          requests++;
          return _playbackResponse(ticket: 'ticket$requests');
        }),
        controllerFactory: (uri, headers) {
          credentials.add(headers['x-test-auth']!);
          expect(uri.queryParameters['ticket'], headers['x-test-auth']);
          final firstAttempt = controllers.isEmpty;
          final controller = _TestVideoController(() async {
            if (firstAttempt) throw StateError('expired test credential');
          });
          controllers.add(controller);
          return controller;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(credentials, ['ticket1', 'ticket2']);
    expect(controllers.first.wasDisposed, isTrue);
    expect(controllers.last.playCalls, 1);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('access denied is shown without creating a player',
      (tester) async {
    var controllersCreated = 0;
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 1,
        dramaTitle: 'Example drama',
        client: MockClient((_) async => http.Response('{}', 403)),
        controllerFactory: (_, __) {
          controllersCreated++;
          return _TestVideoController(() async {});
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('此剧集需要登录或访问授权，当前无法播放'), findsOneWidget);
    expect(controllersCreated, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('leaving before playback response does not create a controller',
      (tester) async {
    final response = Completer<http.Response>();
    var controllersCreated = 0;
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(
        dramaId: 1,
        episode: 1,
        dramaTitle: 'Example drama',
        client: MockClient((_) => response.future),
        controllerFactory: (_, __) {
          controllersCreated++;
          return _TestVideoController(() async {});
        },
      ),
    ));
    await tester.pumpWidget(const SizedBox());
    response.complete(_playbackResponse());
    await tester.pump();

    expect(controllersCreated, 0);
    expect(tester.takeException(), isNull);
  });
}
