import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'video_api.dart';

const _apiBases = [
  'https://huangguoai.com',
  'https://ctb09.ir95e08v.cc',
];

int? _integer(dynamic value) =>
    value is int ? value : int.tryParse(value.toString());

void main() {
  runApp(const HuangguoVIPApp());
}

class HuangguoVIPApp extends StatelessWidget {
  final http.Client? client;

  const HuangguoVIPApp({super.key, this.client});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '黄果短剧 VIP版',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: HomePage(client: client),
    );
  }
}

class HomePage extends StatefulWidget {
  final http.Client? client;

  const HomePage({super.key, this.client});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<Map<String, dynamic>> _dramas = [];
  late final http.Client _client = widget.client ?? http.Client();
  bool _loading = true;
  int _currentPage = 0;
  int _requestId = 0;
  bool _hasMore = true;
  String? _error;
  String _filterStatus = 'all';
  String _filterSort = 'hot';
  bool _isVIP = true;

  @override
  void initState() {
    super.initState();
    _loadVIPStatus();
    _loadDramas(reset: true);
  }

  Future<void> _loadVIPStatus() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isVIP = prefs.getBool('isVIP') ?? true;
    });
  }

  Future<void> _loadDramas({bool reset = false}) async {
    if (_loading && !reset) return;
    final requestId = ++_requestId;
    final page = reset ? 1 : _currentPage + 1;
    final params = <String, String>{
      'page': page.toString(),
      'sort': _filterSort,
      if (_filterStatus == 'completed') 'is_finished': '1',
      if (_filterStatus == 'unfinished') 'is_finished': '0',
    };
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _dramas.clear();
        _currentPage = 0;
        _hasMore = true;
      }
    });

    for (final apiBase in _apiBases) {
      if (!mounted || requestId != _requestId) return;
      try {
        final uri =
            Uri.parse('$apiBase/api/videos').replace(queryParameters: params);
        final response = await _client.get(
          uri,
          headers: {
            'Accept': 'application/json',
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
          },
        ).timeout(const Duration(seconds: 10));
        if (!mounted || requestId != _requestId) return;

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['status'] == 1 && data['data'] != null) {
            final items = data['data']['items'] as List<dynamic>?;
            if (items != null) {
              final dramas = items.map((item) {
                final id = _integer(item['id']);
                if (id == null) {
                  throw const FormatException('Missing drama ID');
                }
                return <String, dynamic>{
                  'id': id,
                  'title': item['title']?.toString() ?? '',
                  'cover': item['cover']?.toString() ?? '',
                  'score': double.tryParse('${item['score']}') ?? 0.0,
                  'episodes': _integer(item['episode_count']) ?? 1,
                  'isFinished': item['is_finished'] == true ||
                      _integer(item['is_finished']) == 1,
                  'tags': item['tags'] is List ? item['tags'] : [],
                  'desc': item['description']?.toString() ?? '',
                };
              }).toList();
              final pagination = data['data']['pagination'];
              final totalPages =
                  pagination is Map ? _integer(pagination['pages']) : null;
              setState(() {
                _dramas.addAll(dramas);
                _currentPage = page;
                _hasMore = items.isNotEmpty &&
                    (totalPages == null || page < totalPages);
                _loading = false;
              });
              return;
            }
          }
        }
      } catch (e) {
        debugPrint('API error: $e');
        continue;
      }
    }

    if (!mounted || requestId != _requestId) return;
    setState(() {
      _loading = false;
      _error = '加载失败，请检查网络后重试';
    });
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('黄果短剧'),
            if (_isVIP)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'VIP',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const HistoryPage()),
            ),
          ),
        ],
      ),
      body: _loading && _dramas.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _dramas.isEmpty && _error != null
              ? _LoadError(message: _error!, onRetry: () => _loadDramas())
              : _dramas.isEmpty
                  ? const Center(child: Text('暂无短剧'))
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 3 / 4,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      padding: const EdgeInsets.all(8),
                      itemCount: _dramas.length + (_hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == _dramas.length) {
                          return Center(
                            child: _loading
                                ? const CircularProgressIndicator()
                                : ElevatedButton(
                                    onPressed: () => _loadDramas(),
                                    child:
                                        Text(_error == null ? '加载更多' : '重试加载'),
                                  ),
                          );
                        }
                        final drama = _dramas[index];
                        return DramaCard(
                          drama: drama,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => DetailPage(
                                dramaId: drama['id'],
                                client: widget.client,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }

  Future<void> _showFilterDialog() async {
    var status = _filterStatus;
    var sort = _filterSort;
    final applied = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Text('筛选条件'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('状态'),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('全部'),
                    selected: status == 'all',
                    onSelected: (selected) {
                      updateDialog(() => status = 'all');
                    },
                  ),
                  FilterChip(
                    label: const Text('已完结'),
                    selected: status == 'completed',
                    onSelected: (selected) {
                      updateDialog(() => status = 'completed');
                    },
                  ),
                  FilterChip(
                    label: const Text('连载中'),
                    selected: status == 'unfinished',
                    onSelected: (selected) {
                      updateDialog(() => status = 'unfinished');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('排序'),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('热门'),
                    selected: sort == 'hot',
                    onSelected: (selected) {
                      updateDialog(() => sort = 'hot');
                    },
                  ),
                  FilterChip(
                    label: const Text('最新'),
                    selected: sort == 'new',
                    onSelected: (selected) {
                      updateDialog(() => sort = 'new');
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || applied != true) return;
    _filterStatus = status;
    _filterSort = sort;
    await _loadDramas(reset: true);
  }
}

class _LoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _LoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class DramaCard extends StatelessWidget {
  final Map<String, dynamic> drama;
  final VoidCallback onTap;

  const DramaCard({super.key, required this.drama, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Image.network(
                drama['cover'],
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: Colors.grey[800],
                    child: const Center(child: Icon(Icons.error)),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drama['title'],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          drama['score'].toStringAsFixed(1),
                          style: const TextStyle(
                              fontSize: 10, color: Colors.black),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          drama['isFinished']
                              ? '全${drama['episodes']}集'
                              : '更新至${drama['episodes']}集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DetailPage extends StatefulWidget {
  final int dramaId;
  final http.Client? client;

  const DetailPage({super.key, required this.dramaId, this.client});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final http.Client _client = widget.client ?? http.Client();
  late final VideoApi _api = VideoApi(
    client: _client,
    baseUrls: _apiBases.map(Uri.parse).toList(),
  );
  VideoDetail? _drama;
  List<int> _episodes = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final drama = await _api.fetchDetail(widget.dramaId);
      if (!mounted) return;
      setState(() {
        _drama = drama;
        _episodes = drama.episodes.map((episode) => episode.number).toList()
          ..sort();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            e is VideoApiException && e.kind == VideoApiErrorKind.accessDenied
                ? '此内容需要登录或访问授权，当前无法查看'
                : '无法加载详情，请检查网络后重试';
      });
    }
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_drama?.title ?? '详情'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _drama == null
              ? _LoadError(
                  message: _error ?? '加载失败',
                  onRetry: _loadDetail,
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_drama!.cover != null)
                        Image.network(
                          _drama!.cover.toString(),
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox(
                                  height: 120,
                                  child: Center(
                                      child: Icon(Icons.image_not_supported))),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _drama!.title,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  _drama!.isFinished ? '已完结' : '连载中',
                                  style: const TextStyle(color: Colors.amber),
                                ),
                                const SizedBox(width: 16),
                                Text(
                                  _drama!.isFinished
                                      ? '全${_drama!.totalEpisodes}集'
                                      : _episodes.isEmpty
                                          ? '暂无剧集'
                                          : '更新至${_episodes.last}集',
                                ),
                                const SizedBox(width: 16),
                                Text('${_drama!.score}分'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _drama!.tags
                                  .map((tag) => Chip(
                                        label: Text(tag.toString()),
                                        backgroundColor:
                                            Colors.amber.withOpacity(0.2),
                                      ))
                                  .toList(),
                            ),
                            const SizedBox(height: 16),
                            Text(_drama!.description),
                            const SizedBox(height: 24),
                            const Text(
                              '剧集列表',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            if (_episodes.isEmpty) const Text('暂未获取到可播放剧集'),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _episodes
                                  .map((ep) => ElevatedButton(
                                        onPressed: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => PlayerPage(
                                              dramaId: widget.dramaId,
                                              episode: ep,
                                              dramaTitle: _drama!.title,
                                              client: widget.client,
                                            ),
                                          ),
                                        ),
                                        child: Text('第$ep集'),
                                      ))
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class PlayerPage extends StatefulWidget {
  final int dramaId;
  final int episode;
  final String dramaTitle;
  final http.Client? client;
  final VideoPlayerController Function(Uri, Map<String, String>)?
      controllerFactory;

  const PlayerPage({
    super.key,
    required this.dramaId,
    required this.episode,
    required this.dramaTitle,
    this.client,
    this.controllerFactory,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final http.Client _client = widget.client ?? http.Client();
  late final VideoApi _api = VideoApi(
    client: _client,
    baseUrls: _apiBases.map(Uri.parse).toList(),
  );
  VideoPlayerController? _controller;
  int _requestId = 0;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final requestId = ++_requestId;
    _timer?.cancel();
    final previous = _controller;
    _controller = null;
    if (previous != null) unawaited(previous.dispose());
    setState(() {
      _loading = true;
      _error = null;
    });
    VideoPlayerController? controller;
    try {
      final playback = await _api.fetchPlayback(widget.dramaId, widget.episode);
      if (!mounted || requestId != _requestId) return;
      controller =
          widget.controllerFactory?.call(playback.uri, playback.httpHeaders) ??
              VideoPlayerController.networkUrl(
                playback.uri,
                httpHeaders: playback.httpHeaders,
              );
      _controller = controller;
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || requestId != _requestId) return;

      // 恢复进度后再开始播放，避免先播放开头并覆盖已保存的进度。
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || requestId != _requestId) return;
      final savedTime =
          prefs.getDouble('progress_${widget.dramaId}_${widget.episode}');
      if (savedTime != null &&
          savedTime.isFinite &&
          savedTime > 0 &&
          savedTime < controller.value.duration.inSeconds) {
        await controller.seekTo(Duration(seconds: savedTime.toInt()));
        if (!mounted || requestId != _requestId) return;
      }
      await controller.play();
      if (!mounted || requestId != _requestId) return;
      setState(() => _loading = false);
      _startProgressTimer();
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      _controller = null;
      if (controller != null) unawaited(controller.dispose());
      setState(() {
        _loading = false;
        _error =
            e is VideoApiException && e.kind == VideoApiErrorKind.accessDenied
                ? '此剧集需要登录或访问授权，当前无法播放'
                : '视频加载失败，请重试';
      });
    }
  }

  void _startProgressTimer() {
    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_controller != null && _controller!.value.isInitialized) {
        _saveProgress();
      }
    });
  }

  Future<void> _saveProgress() async {
    final controller = _controller;
    if (controller != null &&
        controller.value.isInitialized &&
        !controller.value.hasError) {
      final position = controller.value.position.inSeconds.toDouble();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(
          'progress_${widget.dramaId}_${widget.episode}',
          position,
        );
        await prefs.setInt('last_drama_id', widget.dramaId);
        await prefs.setInt('last_episode', widget.episode);
      } catch (e) {
        debugPrint('Saving progress failed: $e');
      }
    }
  }

  @override
  void dispose() {
    ++_requestId;
    _timer?.cancel();
    unawaited(_saveProgress());
    final controller = _controller;
    _controller = null;
    if (controller != null) unawaited(controller.dispose());
    if (widget.client == null) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.dramaTitle} - 第${widget.episode}集'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null || _controller == null
              ? _LoadError(
                  message: _error ?? '播放地址无效',
                  onRetry: _initPlayer,
                )
              : SafeArea(
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _controller!,
                    builder: (context, value, child) {
                      if (value.hasError) {
                        return _LoadError(
                          message: '播放中断，请重试',
                          onRetry: _initPlayer,
                        );
                      }
                      return Column(
                        children: [
                          Expanded(
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: value.aspectRatio,
                                child: VideoPlayer(_controller!),
                              ),
                            ),
                          ),
                          VideoProgressIndicator(_controller!,
                              allowScrubbing: true),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.replay_10),
                                onPressed: () => _controller!.seekTo(
                                  _controller!.value.position -
                                      const Duration(seconds: 10),
                                ),
                              ),
                              IconButton(
                                icon: Icon(value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow),
                                onPressed: () {
                                  value.isPlaying
                                      ? _controller!.pause()
                                      : _controller!.play();
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.forward_10),
                                onPressed: () => _controller!.seekTo(
                                  _controller!.value.position +
                                      const Duration(seconds: 10),
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastDramaId = prefs.getInt('last_drama_id');
    final lastEpisode = prefs.getInt('last_episode');

    if (lastDramaId != null && lastEpisode != null) {
      setState(() {
        _history = [
          {
            'dramaId': lastDramaId,
            'episode': lastEpisode,
          }
        ];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('观看历史'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('last_drama_id');
              await prefs.remove('last_episode');
              if (!mounted) return;
              setState(() => _history.clear());
            },
          ),
        ],
      ),
      body: _history.isEmpty
          ? const Center(child: Text('暂无观看历史'))
          : ListView.builder(
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final item = _history[index];
                return ListTile(
                  title: Text('短剧 ID: ${item['dramaId']}'),
                  subtitle: Text('第${item['episode']}集'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          DetailPage(dramaId: item['dramaId']),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
