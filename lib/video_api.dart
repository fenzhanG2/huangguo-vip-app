import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum VideoApiErrorKind { network, http, accessDenied, invalidResponse }

/// Deliberately excludes response bodies, URLs, and server-provided messages.
class VideoApiException implements Exception {
  final VideoApiErrorKind kind;
  final int? statusCode;

  const VideoApiException(this.kind, {this.statusCode});

  @override
  String toString() => 'VideoApiException(${kind.name}'
      '${statusCode == null ? '' : ', HTTP $statusCode'})';
}

class VideoEpisode {
  final int number;
  final int status;

  const VideoEpisode({required this.number, required this.status});
}

class VideoDetail {
  final int id;
  final String title;
  final Uri? cover;
  final String description;
  final List<String> tags;
  final double score;
  final int totalEpisodes;
  final bool isFinished;
  final List<VideoEpisode> episodes;

  VideoDetail({
    required this.id,
    required this.title,
    required this.cover,
    required this.description,
    required List<String> tags,
    required this.score,
    required this.totalEpisodes,
    required this.isFinished,
    required List<VideoEpisode> episodes,
  })  : tags = List.unmodifiable(tags),
        episodes = List.unmodifiable(episodes);
}

/// Request-scoped playback credentials; callers must not persist this object.
class VideoPlayback {
  final Uri uri;
  final Map<String, String> httpHeaders;

  VideoPlayback({required this.uri, required Map<String, String> httpHeaders})
      : httpHeaders = Map.unmodifiable(httpHeaders);
}

class VideoApi {
  final http.Client _client;
  final List<Uri> _baseUrls;
  final Duration _timeout;

  /// The caller owns [client] and remains responsible for closing it.
  VideoApi({
    required http.Client client,
    required List<Uri> baseUrls,
    Duration timeout = const Duration(seconds: 10),
  })  : _client = client,
        _baseUrls = List.unmodifiable(baseUrls),
        _timeout = timeout {
    if (_baseUrls.isEmpty || _baseUrls.any((uri) => !_isHttpUri(uri))) {
      throw ArgumentError('baseUrls must contain absolute HTTP(S) URLs.');
    }
    if (timeout <= Duration.zero || timeout > const Duration(minutes: 1)) {
      throw ArgumentError('timeout must be positive and at most one minute.');
    }
  }

  Future<VideoDetail> fetchDetail(int videoId) async {
    _checkPositiveArgument(videoId, 'videoId');
    final data = await _request('/api/videos/$videoId');
    _checkIdentity(data, videoId);

    final rawEpisodes = data['episodes'];
    if (rawEpisodes is! List) _invalid();
    final episodes = <VideoEpisode>[];
    final numbers = <int>{};
    for (final rawEpisode in rawEpisodes) {
      final episode = _object(rawEpisode);
      final number = _positiveInt(episode['ep_num']);
      final status = _integer(episode['status']);
      if (status == null || !numbers.add(number)) _invalid();
      episodes.add(VideoEpisode(number: number, status: status));
    }

    final total = data['total_episodes'] ?? data['episode_count'];
    final totalEpisodes = total == null ? episodes.length : _integer(total);
    if (totalEpisodes == null || totalEpisodes < 0) _invalid();
    final rawScore = data['score'];
    final score = rawScore == null ? 0.0 : double.tryParse('$rawScore');
    if (score == null || !score.isFinite) _invalid();

    final rawTags = data['tags'] ?? <dynamic>[];
    if (rawTags is! List || rawTags.any((tag) => tag is! String)) _invalid();
    final cover = _string(data['cover']);

    return VideoDetail(
      id: videoId,
      title: _string(data['title'], required: true),
      cover: cover.isEmpty ? null : _httpUri(cover),
      description: _string(data['description']),
      tags: rawTags.cast<String>(),
      score: score,
      totalEpisodes: totalEpisodes,
      isFinished: _boolean(data['is_finished']),
      episodes: episodes,
    );
  }

  Future<VideoPlayback> fetchPlayback(int videoId, int episode) async {
    _checkPositiveArgument(videoId, 'videoId');
    _checkPositiveArgument(episode, 'episode');
    final data = await _request(
      '/api/videos/$videoId/episodes/$episode/playback',
      post: true,
    );
    _checkIdentity(data, videoId, required: true);
    if (_positiveInt(data['ep']) != episode ||
        data['manifest_method'] != 'GET') {
      _invalid();
    }
    final uri = _httpUri(_object(data['streams'])['main']);
    if (uri.scheme != 'https') _invalid();
    final headers = <String, String>{};
    final rawCdn = data['cdn'];
    if (rawCdn != null) {
      final cdn = _object(rawCdn);
      final m3u8Enabled = _boolean(cdn['m3u8Enabled']);
      if (m3u8Enabled && uri.path.toLowerCase().endsWith('.m3u8')) {
        final authKey = _string(cdn['authKey'], required: true);
        final authValue = _string(cdn['authValue'], required: true);
        final app = _string(cdn['app'], required: true);
        if (!_headerName.hasMatch(authKey) ||
            !_validHeaderValue(authValue) ||
            !_validHeaderValue(app) ||
            authKey.toLowerCase() == 'x-cdn-app') {
          _invalid();
        }
        headers[authKey] = authValue;
        headers['x-cdn-app'] = app;
      }
    }
    return VideoPlayback(uri: uri, httpHeaders: headers);
  }

  Future<Map<String, dynamic>> _request(String path,
      {bool post = false}) async {
    for (var index = 0; index < _baseUrls.length; index++) {
      final hasFallback = index + 1 < _baseUrls.length;
      final uri = _baseUrls[index].resolve(path);
      http.Response response;
      try {
        response = await (post
                ? _client.post(
                    uri,
                    headers: const {
                      'Accept': 'application/json',
                      'Content-Type': 'application/json',
                    },
                    body: '{}',
                  )
                : _client
                    .get(uri, headers: const {'Accept': 'application/json'}))
            .timeout(_timeout);
      } on TimeoutException {
        if (hasFallback) continue;
        throw const VideoApiException(VideoApiErrorKind.network);
      } on http.ClientException {
        if (hasFallback) continue;
        throw const VideoApiException(VideoApiErrorKind.network);
      } on IOException {
        if (hasFallback) continue;
        throw const VideoApiException(VideoApiErrorKind.network);
      }

      final status = response.statusCode;
      if (status == 401 || status == 403) {
        throw VideoApiException(VideoApiErrorKind.accessDenied,
            statusCode: status);
      }
      if (status >= 500 && status <= 599 && hasFallback) continue;
      if (status < 200 || status >= 300) {
        throw VideoApiException(VideoApiErrorKind.http, statusCode: status);
      }

      final Map<String, dynamic> envelope;
      try {
        envelope = _object(jsonDecode(response.body));
      } on FormatException {
        _invalid();
      }
      final apiStatus = _integer(envelope['status']);
      if (apiStatus == null) _invalid();
      // Application failures, including access denials, are never retried
      // against another origin or another playback mechanism.
      if (apiStatus != 1) {
        throw const VideoApiException(VideoApiErrorKind.accessDenied);
      }
      return _object(envelope['data']);
    }
    throw const VideoApiException(VideoApiErrorKind.network);
  }
}

final _headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

bool _validHeaderValue(String value) =>
    value.isNotEmpty &&
    !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

bool _isHttpUri(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.hasAuthority &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

Uri _httpUri(dynamic value) {
  if (value is! String) _invalid();
  final uri = Uri.tryParse(value);
  if (uri == null || !_isHttpUri(uri)) _invalid();
  return uri;
}

Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

int? _integer(dynamic value) => value is int
    ? value
    : value is String
        ? int.tryParse(value)
        : null;

int _positiveInt(dynamic value) {
  final integer = _integer(value);
  if (integer == null || integer <= 0) _invalid();
  return integer;
}

String _string(dynamic value, {bool required = false}) {
  if (value == null && !required) return '';
  if (value is! String || (required && value.isEmpty)) _invalid();
  return value;
}

bool _boolean(dynamic value) {
  if (value == null) return false;
  if (value is bool) return value;
  final integer = _integer(value);
  if (integer == 0) return false;
  if (integer == 1) return true;
  _invalid();
}

void _checkIdentity(Map<String, dynamic> data, int id,
    {bool required = false}) {
  if ((required || data.containsKey('id')) && _positiveInt(data['id']) != id) {
    _invalid();
  }
}

void _checkPositiveArgument(int value, String name) {
  if (value <= 0) throw ArgumentError('$name must be positive.');
}

Never _invalid() =>
    throw const VideoApiException(VideoApiErrorKind.invalidResponse);
