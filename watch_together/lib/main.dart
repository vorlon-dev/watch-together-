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
            builder: (_) => RoomScreen(roomId: roomId, isHost: true)));
  }

  void _joinRoom() {
    final id = _roomController.text.trim();
    if (id.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a room ID')));
      return;
    }
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => RoomScreen(roomId: id, isHost: false)));
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
                    foregroundColor: Colors.white)),
            const SizedBox(height: 30),
            const Text('OR', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 20),
            TextField(
                controller: _roomController,
                decoration: const InputDecoration(
                    hintText: 'Enter Room ID',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 16))),
            const SizedBox(height: 15),
            ElevatedButton.icon(
                onPressed: _joinRoom,
                icon: const Icon(Icons.login),
                label: const Text('Join Room'),
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white)),
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
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
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
      ..addJavaScriptChannel('FlutterBridge',
          onMessageReceived: _onWebViewMessage)
      ..loadRequest(
          Uri.parse('$SERVER_URL/player.html')); // loads sync.js automatically

    // Poll for __playerReady
    Timer.periodic(const Duration(milliseconds: 300), (_) async {
      if (!mounted || _webViewReady) return;
      try {
        final res = await _webViewController
            .runJavaScriptReturningResult('window.__playerReady');
        if (res.toString() == 'true') {
          debugPrint("✅ Player ready");
          setState(() {
            _webViewReady = true;
            _isLoading = false;
          });
          _forceShowTimer?.cancel();
          // Set host role in JS
          _webViewController.runJavaScript('window.setHost(${widget.isHost})');
          if (_pendingCommand != null) {
            _webViewController.runJavaScript(
                'applySyncCommand(${jsonEncode(_pendingCommand)})');
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

  void _connectSocket() {
    socket = IO.io(SERVER_URL, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true
    });

    socket.onConnect((_) {
      debugPrint('✅ Connected to server');
      if (widget.isHost)
        socket.emit('create-room', widget.roomId);
      else
        socket.emit('join-room', widget.roomId);
    });

    socket.on('room-created', (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Room created: ${widget.roomId}')));
    });

    socket.on('room-joined', (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Joined room successfully')));
    });

    socket.on('room-error', (data) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(data.toString())));
        Navigator.pop(context);
      }
    });

    socket.on('current-video', (videoId) {
      _loadedVideoId = videoId as String;
      _webViewController.runJavaScript('loadVideo("$videoId")');
      if (_isLoading) setState(() => _isLoading = false);
      _enterFullscreen();
    });

    if (!widget.isHost) {
      socket.on('sync-command', (cmd) {
        if (!_webViewReady) {
          _pendingCommand = cmd as Map<String, dynamic>;
          return;
        }
        _webViewController
            .runJavaScript('applySyncCommand(${jsonEncode(cmd)})');
      });
    }
  }

  // Host actions
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Invalid YouTube URL')));
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
        r'(?:https?:\/\/)?(?:www\.)?(?:youtube\.com\/(?:watch\?v=|embed\/|shorts\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})');
    final match = regex.firstMatch(url);
    return match?.group(1);
  }

  void _onWebViewMessage(JavaScriptMessage message) {
    final msg = message.message;
    debugPrint('WebView msg: $msg');
    // state changes are handled inside sync.js and sent as socket commands from host
    // so nothing needed here besides logging
  }

  void _startPeriodicSync() {
    // The periodic sync is already handled by the host's client.js (web) or by our host logic?
    // For Flutter host, we also send a sync every 3 seconds
    Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || !widget.isHost || !_webViewReady) return;
      _webViewController
          .runJavaScriptReturningResult('window.__currentTime')
          .then((timeJs) {
        final time = double.tryParse(timeJs.toString()) ?? 0.0;
        socket.emit('host-command', [
          widget.roomId,
          {'action': 'sync', 'time': time}
        ]);
      }).catchError((_) {});
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
                                border: OutlineInputBorder()))),
                    const SizedBox(width: 10),
                    ElevatedButton(
                        onPressed: _loadVideo,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red),
                        child: const Text('Load')),
                  ],
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  if (_isLoading)
                    const Center(
                        child: CircularProgressIndicator(color: Colors.red))
                  else
                    WebViewWidget(controller: _webViewController),
                  // Custom Play / Pause overlay
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
                              backgroundColor: Colors.white70,
                              onPressed: _hostPlay,
                              child: const Icon(Icons.play_arrow,
                                  color: Colors.black)),
                          const SizedBox(height: 10),
                          FloatingActionButton(
                              heroTag: 'pause',
                              mini: true,
                              backgroundColor: Colors.white70,
                              onPressed: _hostPause,
                              child:
                                  const Icon(Icons.pause, color: Colors.black)),
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
