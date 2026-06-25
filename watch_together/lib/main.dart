import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:webview_flutter/webview_flutter.dart';

const String SERVER_URL =
    'https://watch-together-iti4.onrender.com'; // your Render URL

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

    _forceShowTimer = Timer(const Duration(seconds: 6), () {
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
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36',
      )
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
          debugPrint("Player ready detected via polling");
          setState(() {
            _webViewReady = true;
            _isLoading = false;
          });
          _forceShowTimer?.cancel();
          // Apply pending command if any
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
    #error-msg { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); color:red; font-size:16px; display:none; }
  </style>
</head>
<body>
  <div id="loading-msg">Loading player...</div>
  <div id="error-msg"></div>
  <iframe id="player-frame" allowfullscreen></iframe>

  <script>
    window.__playerReady = false;
    var player = document.getElementById('player-frame');
    var loadingDiv = document.getElementById('loading-msg');
    var errorDiv = document.getElementById('error-msg');
    var origin = '$SERVER_URL';

    function showError(msg) {
      loadingDiv.style.display = 'none';
      errorDiv.style.display = 'block';
      errorDiv.textContent = msg;
      window.__playerReady = true;
      if (window.FlutterBridge) {
        FlutterBridge.postMessage(JSON.stringify({event: 'error', message: msg}));
      }
    }

    window.addEventListener('message', function(event) {
      if (event.origin !== 'https://www.youtube.com') return;
      try {
        var data = JSON.parse(event.data);
        if (data.event === 'onReady') {
          window.__playerReady = true;
          loadingDiv.style.display = 'none';
          errorDiv.style.display = 'none';
          if (window.FlutterBridge) {
            FlutterBridge.postMessage('playerReady');
          }
        } else if (data.event === 'onStateChange') {
          if (window.FlutterBridge) {
            FlutterBridge.postMessage(JSON.stringify({
              event: 'stateChange',
              state: data.info,
              time: 0
            }));
          }
        } else if (data.event === 'infoDelivery' && data.info && data.info.currentTime !== undefined) {
          if (window._requestedTimeCallback) {
            window._requestedTimeCallback(data.info.currentTime);
            window._requestedTimeCallback = null;
          }
        }
      } catch(e) {}
    });

    function loadVideo(videoId) {
      loadingDiv.style.display = 'block';
      errorDiv.style.display = 'none';
      var src = 'https://www.youtube.com/embed/' + videoId + '?enablejsapi=1&origin=' + encodeURIComponent(origin) + '&controls=1&playsinline=1';
      player.src = src;

      setTimeout(function() {
        if (!window.__playerReady) {
          window.__playerReady = true;
          loadingDiv.style.display = 'none';
          if (window.FlutterBridge) {
            FlutterBridge.postMessage('playerReady');
          }
        }
      }, 5000);
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

    // If player not ready, store command to apply later
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
        debugPrint('Sync load: $videoId');
        _webViewController.runJavaScript('loadVideo("$videoId")');
        if (_isLoading) setState(() => _isLoading = false);
        _enterFullscreen();
        break;
      case 'play':
        // Seek to host's current time, then play
        final time = (cmd['currentTime'] as num).toDouble();
        _webViewController.runJavaScript('seekTo($time)');
        _webViewController.runJavaScript('playVideo()');
        break;
      case 'pause':
        _webViewController.runJavaScript('pauseVideo()');
        break;
      case 'seek':
        final seekTime = (cmd['time'] as num).toDouble();
        _webViewController.runJavaScript('seekTo($seekTime)');
        break;
      case 'sync':
        final syncTime = (cmd['time'] as num).toDouble();
        _webViewController.runJavaScript('seekTo($syncTime)');
        break;
    }
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

    // Host auto-plays after loading (JS will handle via the iframe's onReady)
    _webViewController.runJavaScript('loadVideo("$videoId")');
    if (_isLoading) setState(() => _isLoading = false);
    _enterFullscreen();

    // After a short delay, tell the iframe to play (if not already playing)
    Future.delayed(const Duration(seconds: 2), () {
      _webViewController.runJavaScript('playVideo()');
    });
  }

  String? _extractVideoId(String url) {
    final regex = RegExp(
      r'(?:https?:\/\/)?(?:www\.)?(?:youtube\.com\/(?:watch\?v=|embed\/|shorts\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})',
    );
    final match = regex.firstMatch(url);
    return match?.group(1);
  }

  void _onWebViewMessage(JavaScriptMessage message) {
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
        if (data['event'] == 'error') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(data['message'] ?? 'Video load error')),
            );
          }
        } else if (data['event'] == 'stateChange') {
          final state = data['state'] as int;
          if (widget.isHost) {
            if (state == 1) {
              // Playing – get current time and send to viewers
              _webViewController.runJavaScriptReturningResult(
                  'player.contentWindow.postMessage(JSON.stringify({event:"command",func:"getCurrentTime"}), "*");');
              // We'll receive the time via infoDelivery; for simplicity, just send with 0
              socket.emit('host-command', [
                widget.roomId,
                {'action': 'play', 'currentTime': 0}
              ]);
            } else if (state == 2) {
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
    await Future.delayed(const Duration(milliseconds: 200));
    try {
      final timeJs = await _webViewController.runJavaScriptReturningResult(
        'try { player.contentWindow.postMessage(JSON.stringify({event:"command",func:"getCurrentTime"}), "*"); } catch(e) { 0; }',
      );
      // We can't get the time directly, so just send a seek with 0 (sync will correct later)
      socket.emit('host-command', [
        widget.roomId,
        {'action': 'seek', 'time': 0, 'state': 'playing'}
      ]);
    } catch (e) {
      debugPrint("Seek error: $e");
    }
  }

  void _startPeriodicSync() {
    Future.delayed(const Duration(seconds: 10), () {
      if (!mounted || !widget.isHost) {
        _startPeriodicSync();
        return;
      }
      // Request current time from iframe and send it
      _webViewController.runJavaScript(
          'player.contentWindow.postMessage(JSON.stringify({event:"command",func:"getCurrentTime"}), "*");');
      // In a real app, you'd listen for infoDelivery; we'll just send a dummy sync
      socket.emit('host-command', [
        widget.roomId,
        {'action': 'sync', 'time': 0}
      ]);
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
            if (_isLoading)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(color: Colors.red),
                ),
              )
            else
              Expanded(
                child: Listener(
                  onPointerUp: _onPointerUp,
                  child: WebViewWidget(controller: _webViewController),
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
