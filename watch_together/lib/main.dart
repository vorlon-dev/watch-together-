import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:webview_flutter/webview_flutter.dart';

const String SERVER_URL = 'https://watch-together-iti4.onrender.com';

void main() => runApp(const WatchTogetherApp());

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watch Together',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _roomController = TextEditingController();

  void _createRoom() {
    final roomId =
        DateTime.now().millisecondsSinceEpoch.toRadixString(36).substring(2, 8);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoomScreen(roomId: roomId, isHost: true),
      ),
    );
  }

  void _joinRoom() {
    final id = _roomController.text.trim();
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a room ID')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoomScreen(roomId: id, isHost: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watch Together')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: _createRoom,
              icon: const Icon(Icons.add),
              label: const Text('Create a Room'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 30),
            const Text('OR', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 20),
            TextField(
              controller: _roomController,
              decoration: const InputDecoration(
                hintText: 'Enter Room ID',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              onPressed: _joinRoom,
              icon: const Icon(Icons.login),
              label: const Text('Join Room'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== ROOM SCREEN =====================
class RoomScreen extends StatefulWidget {
  final String roomId;
  final bool isHost;
  const RoomScreen({super.key, required this.roomId, required this.isHost});
  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late IO.Socket socket;
  late WebViewController _webViewController;
  bool _webViewReady = false;
  bool _isLoading = true;
  String? _loadedVideoId;
  final _urlController = TextEditingController();
  Timer? _forceShowTimer;
  bool _isFullscreen = false;
  Map<String, dynamic>? _pendingCommand;

  @override
  void initState() {
    super.initState();
    _setOrientationPortrait();
    _createWebViewController();
    _connectSocket();
    if (widget.isHost) _startPeriodicSync();

    _forceShowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
        if (_loadedVideoId != null) {
          _webViewController.runJavaScript('loadVideo("$_loadedVideoId")');
          _enterFullscreen();
        }
      }
    });
  }

  void _setOrientationPortrait() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _enterFullscreen() {
    if (!mounted) return;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() => _isFullscreen = true);
  }

  void _exitFullscreen() {
    _setOrientationPortrait();
    if (mounted) setState(() => _isFullscreen = false);
  }

  void _createWebViewController() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: _onWebViewMessage,
      )
      ..loadHtmlString(_playerHtml(), baseUrl: '$SERVER_URL/');

    Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (!mounted || _webViewReady) return;
      try {
        final res = await _webViewController
            .runJavaScriptReturningResult('window.__playerReady');
        if (res.toString() == 'true') {
          debugPrint("✅ Player ready (polling)");
          setState(() {
            _webViewReady = true;
            _isLoading = false;
          });
          _forceShowTimer?.cancel();
          if (_pendingCommand != null) {
            _applyCommand(_pendingCommand!);
            _pendingCommand = null;
          }
          if (_loadedVideoId != null) {
            _webViewController.runJavaScript('loadVideo("$_loadedVideoId")');
            _enterFullscreen();
          }
        }
      } catch (e) {
        debugPrint("Poll error: $e");
      }
    });
  }

  String _playerHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <base href="$SERVER_URL/">
  <style>
    body, html { margin:0; padding:0; width:100%; height:100%; background:#000; overflow:hidden; }
    #player-frame { width:100%; height:100%; border:none; }
    #loading-msg { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); color:#fff; font-size:18px; }
  </style>
</head>
<body>
  <div id="loading-msg">Loading player…</div>
  <iframe id="player-frame" allowfullscreen></iframe>

  <script>
    window.__playerReady = false;
    window.__currentTime = 0;
    var player = document.getElementById('player-frame');
    var origin = '$SERVER_URL';

    setTimeout(function() {
      window.__playerReady = true;
      document.getElementById('loading-msg').style.display = 'none';
    }, 3000);

    setInterval(function() {
      if (player && player.contentWindow) {
        player.contentWindow.postMessage('{"event":"command","func":"getCurrentTime","args":""}', '*');
      }
    }, 500);

    window.addEventListener('message', function(event) {
      if (event.origin !== 'https://www.youtube.com') return;
      try {
        var data = JSON.parse(event.data);
        if (data.event === 'infoDelivery' && data.info && data.info.currentTime !== undefined) {
          window.__currentTime = data.info.currentTime;
        } else if (data.event === 'onStateChange') {
          if (window.FlutterBridge) {
            FlutterBridge.postMessage(JSON.stringify({
              event: 'stateChange',
              state: data.info,
              time: window.__currentTime
            }));
          }
        }
      } catch(e) {}
    });

    function loadVideo(videoId) {
      document.getElementById('loading-msg').style.display = 'block';
      var src = 'https://www.youtube.com/embed/' + videoId + '?enablejsapi=1&origin=' + encodeURIComponent(origin) + '&controls=1&playsinline=1';
      player.src = src;
      setTimeout(function() {
        playVideo();
      }, 1500);
    }

    function playVideo() {
      if (player.contentWindow) {
        player.contentWindow.postMessage('{"event":"command","func":"playVideo","args":""}', '*');
      }
    }
    function pauseVideo() {
      if (player.contentWindow) {
        player.contentWindow.postMessage('{"event":"command","func":"pauseVideo","args":""}', '*');
      }
    }
    function seekTo(seconds) {
      if (player.contentWindow) {
        player.contentWindow.postMessage('{"event":"command","func":"seekTo","args":' + seconds + '}', '*');
      }
    }
  </script>
</body>
</html>
    ''';
  }

  void _connectSocket() {
    socket = IO.io(SERVER_URL, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    socket.onConnect((_) {
      debugPrint('✅ Connected to server');
      if (widget.isHost) {
        socket.emit('create-room', widget.roomId);
      } else {
        socket.emit('join-room', widget.roomId);
      }
    });

    socket.on('room-created', (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Room created: ${widget.roomId}')),
        );
      }
    });

    socket.on('room-joined', (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Joined room successfully')),
        );
      }
    });

    socket.on('room-error', (data) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data.toString())),
        );
        Navigator.pop(context);
      }
    });

    socket.on('current-video', (videoId) {
      _loadedVideoId = videoId as String;
      debugPrint('Received current-video: $videoId');
      _webViewController.runJavaScript('loadVideo("$videoId")');
      if (_isLoading) setState(() => _isLoading = false);
      _enterFullscreen();
    });

    if (!widget.isHost) {
      socket.on('sync-command', _handleSyncCommand);
    }
  }

  void _handleSyncCommand(dynamic data) {
    final cmd = data as Map<String, dynamic>;
    if (!_webViewReady) {
      _pendingCommand = cmd;
      return;
    }
    _applyCommand(cmd);
  }

  void _applyCommand(Map<String, dynamic> cmd) {
    switch (cmd['action']) {
      case 'load':
        final videoId = cmd['videoId'] as String;
        _loadedVideoId = videoId;
        _webViewController.runJavaScript('loadVideo("$videoId")');
        if (_isLoading) setState(() => _isLoading = false);
        _enterFullscreen();
        break;
      case 'play':
        final time = (cmd['currentTime'] as num?)?.toDouble() ?? 0.0;
        _webViewController.runJavaScript('seekTo($time)');
        _webViewController.runJavaScript('playVideo()');
        break;
      case 'pause':
        _webViewController.runJavaScript('pauseVideo()');
        break;
      case 'seek':
        final seekTime = (cmd['time'] as num?)?.toDouble() ?? 0.0;
        _webViewController.runJavaScript('seekTo($seekTime)');
        break;
      case 'sync':
        final syncTime = (cmd['time'] as num?)?.toDouble() ?? 0.0;
        _webViewController.runJavaScript('seekTo($syncTime)');
        break;
    }
  }

  // ---------- HOST custom buttons actions ----------
  Future<void> _hostPlay() async {
    final timeJs = await _webViewController
        .runJavaScriptReturningResult('window.__currentTime');
    final time = double.tryParse(timeJs.toString()) ?? 0.0;
    socket.emit('host-command', [
      widget.roomId,
      {'action': 'play', 'currentTime': time}
    ]);
    _webViewController.runJavaScript('playVideo()');
  }

  Future<void> _hostPause() async {
    final timeJs = await _webViewController
        .runJavaScriptReturningResult('window.__currentTime');
    final time = double.tryParse(timeJs.toString()) ?? 0.0;
    socket.emit('host-command', [
      widget.roomId,
      {'action': 'pause', 'time': time}
    ]);
    _webViewController.runJavaScript('pauseVideo()');
  }

  void _loadVideo() {
    final url = _urlController.text.trim();
    final videoId = _extractVideoId(url);
    if (videoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid YouTube URL')),
      );
      return;
    }
    _loadedVideoId = videoId;

    socket.emit('host-command', [
      widget.roomId,
      {'action': 'load', 'videoId': videoId}
    ]);

    _webViewController.runJavaScript('loadVideo("$videoId")');
    if (_isLoading) setState(() => _isLoading = false);
    _enterFullscreen();
  }

  String? _extractVideoId(String url) {
    final regex = RegExp(
      r'(?:https?:\/\/)?(?:www\.)?(?:youtube\.com\/(?:watch\?v=|embed\/|shorts\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})',
    );
    final match = regex.firstMatch(url);
    return match?.group(1);
  }

  void _onWebViewMessage(JavaScriptMessage message) async {
    final msg = message.message;
    debugPrint('WebView msg: $msg');
    if (msg == 'playerReady') {
      setState(() {
        _webViewReady = true;
        _isLoading = false;
      });
      _forceShowTimer?.cancel();
      if (_pendingCommand != null) {
        _applyCommand(_pendingCommand!);
        _pendingCommand = null;
      }
      if (_loadedVideoId != null) {
        _webViewController.runJavaScript('loadVideo("$_loadedVideoId")');
        _enterFullscreen();
      }
    } else if (msg.startsWith('{')) {
      try {
        final data = jsonDecode(msg) as Map<String, dynamic>;
        if (data['event'] == 'stateChange') {
          final state = data['state'] as int;
          if (widget.isHost) {
            if (state == 1) {
              // playing
              final timeJs = await _webViewController
                  .runJavaScriptReturningResult('window.__currentTime');
              final time = double.tryParse(timeJs.toString()) ?? 0.0;
              socket.emit('host-command', [
                widget.roomId,
                {'action': 'play', 'currentTime': time}
              ]);
            } else if (state == 2) {
              // paused
              socket.emit('host-command', [
                widget.roomId,
                {'action': 'pause'}
              ]);
            }
          }
        }
      } catch (_) {}
    }
  }

  void _onPointerUp(PointerUpEvent event) async {
    if (!widget.isHost || !_webViewReady) return;
    await Future.delayed(const Duration(milliseconds: 300));
    try {
      final timeJs = await _webViewController
          .runJavaScriptReturningResult('window.__currentTime');
      final time = double.tryParse(timeJs.toString()) ?? 0.0;
      socket.emit('host-command', [
        widget.roomId,
        {'action': 'seek', 'time': time, 'state': 'playing'}
      ]);
    } catch (e) {
      debugPrint("Seek error: $e");
    }
  }

  void _startPeriodicSync() {
    Future.delayed(const Duration(seconds: 5), () async {
      if (!mounted || !widget.isHost || !_webViewReady) {
        _startPeriodicSync();
        return;
      }
      try {
        final timeJs = await _webViewController
            .runJavaScriptReturningResult('window.__currentTime');
        final time = double.tryParse(timeJs.toString()) ?? 0.0;
        socket.emit('host-command', [
          widget.roomId,
          {'action': 'sync', 'time': time}
        ]);
      } catch (_) {}
      _startPeriodicSync();
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (_isFullscreen) {
          _exitFullscreen();
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: _isFullscreen
            ? null
            : AppBar(title: Text('Room: ${widget.roomId}')),
        body: Column(
          children: [
            if (widget.isHost && !_isFullscreen)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          hintText: 'Paste YouTube URL',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _loadVideo,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: const Text('Load'),
                    ),
                  ],
                ),
              ),
            // Player area with custom host buttons
            Expanded(
              child: Stack(
                children: [
                  if (_isLoading)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.red),
                    )
                  else
                    WebViewWidget(controller: _webViewController),
                  // Custom Play / Pause overlay (only for host)
                  if (widget.isHost && !_isLoading)
                    Positioned(
                      bottom: 20,
                      right: 20,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton(
                            heroTag: 'play',
                            mini: true,
                            backgroundColor: Colors.white.withOpacity(0.7),
                            onPressed: _hostPlay,
                            child: const Icon(Icons.play_arrow,
                                color: Colors.black),
                          ),
                          const SizedBox(height: 10),
                          FloatingActionButton(
                            heroTag: 'pause',
                            mini: true,
                            backgroundColor: Colors.white.withOpacity(0.7),
                            onPressed: _hostPause,
                            child: const Icon(Icons.pause, color: Colors.black),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _forceShowTimer?.cancel();
    _urlController.dispose();
    socket.disconnect();
    _setOrientationPortrait();
    super.dispose();
  }
}
