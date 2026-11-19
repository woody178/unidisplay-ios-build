import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const UniDisplayApp());
}

class UniDisplayApp extends StatelessWidget {
  const UniDisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UniDisplay 第二螢幕',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const DisplaySinkScreen(),
    );
  }
}

class DisplaySinkScreen extends StatefulWidget {
  const DisplaySinkScreen({super.key});

  @override
  State<DisplaySinkScreen> createState() => _DisplaySinkScreenState();
}

class _DisplaySinkScreenState extends State<DisplaySinkScreen>
    with WidgetsBindingObserver {
  static const int kUsbListenPort = 23456;

  ServerSocket? _server;
  Socket? _activeSocket;
  bool _isConnected = false;
  String _statusText = '等待 Type-C 連接中（監聽埠 $kUsbListenPort）...';
  String _peerInfo = '';
  List<String> _localIps = [];

  // 影像渲染狀態（使用 ValueNotifier 避免全畫面重建，僅重繪畫布）
  final ValueNotifier<ui.Image?> _frameNotifier = ValueNotifier<ui.Image?>(null);
  Uint8List? _latestPendingBytes;
  bool _isDecoding = false;

  // 效能統計
  int _framesInLastSec = 0;
  int _bytesInLastSec = 0;
  double _currentFps = 0;
  double _currentMbps = 0;
  int _srcWidth = 0;
  int _srcHeight = 0;
  Timer? _statsTimer;
  Timer? _ipRefreshTimer;

  // 顯示控制選項（單頁即時切換）
  bool _showHud = true;
  Timer? _hudAutoHideTimer;
  BoxFit _boxFit = BoxFit.contain;
  int _rotationMode = 0; // 0: 自動, 1: 橫向, 2: 直向
  double _brightnessDim = 0.0; // 0.0 = 100% 亮度, 0.7 = 調暗 70%

  // 備用：主動連線到 PC IP
  final TextEditingController _pcIpCtrl = TextEditingController();
  bool _connectingOut = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startUsbServer();
    _refreshLocalIps();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_isConnected) {
        setState(() {
          _currentFps = _framesInLastSec.toDouble();
          _currentMbps = (_bytesInLastSec * 8) / (1024 * 1024);
          _framesInLastSec = 0;
          _bytesInLastSec = 0;
        });
      }
    });
    _ipRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_isConnected) _refreshLocalIps();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statsTimer?.cancel();
    _ipRefreshTimer?.cancel();
    _hudAutoHideTimer?.cancel();
    _disconnectCurrent();
    _server?.close();
    _frameNotifier.value?.dispose();
    _frameNotifier.dispose();
    _pcIpCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _sendHelloHandshake();
  }

  Future<void> _refreshLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final ips = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          ips.add('${iface.name}: ${addr.address}');
        }
      }
      if (mounted) {
        setState(() => _localIps = ips);
      }
    } catch (_) {}
  }

  Future<void> _startUsbServer() async {
    try {
      await _server?.close();
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        kUsbListenPort,
        shared: true,
      );
      if (mounted) {
        setState(() {
          _statusText = '⚡ 已就緒！請插入 Type-C 線並在 PC 啟動發送端（埠號 $kUsbListenPort）';
        });
      }
      _server!.listen((Socket client) {
        _attachClientSocket(client, 'USB / 直連通道 (${client.remoteAddress.address})');
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = '監聽埠啟動失敗: $e';
        });
      }
    }
  }

  Future<void> _connectToPcHost() async {
    final host = _pcIpCtrl.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _connectingOut = true;
      _statusText = '正在連線至 PC ($host:23457)...';
    });
    try {
      final sock = await Socket.connect(
        host,
        23457,
        timeout: const Duration(seconds: 4),
      );
      _attachClientSocket(sock, '主動連線 PC ($host:23457)');
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusText = '連線 PC 失敗 ($host:23457): $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _connectingOut = false);
      }
    }
  }

  void _attachClientSocket(Socket sock, String label) {
    _disconnectCurrent();
    sock.setOption(SocketOption.tcpNoDelay, true);
    _activeSocket = sock;

    if (mounted) {
      setState(() {
        _isConnected = true;
        _peerInfo = label;
        _statusText = '🟢 已連線：$label';
      });
    }
    _scheduleHudHide();
    _sendHelloHandshake();

    // 高速二進位封包解析緩衝區
    // 封包格式: [4B 'UDSP'][4B payloadLen BE][2B width BE][2B height BE][4B seq BE][payload...]
    final BytesBuilder buffer = BytesBuilder(copy: false);
    int expectedPayloadLen = -1;
    int headerWidth = 0;
    int headerHeight = 0;

    sock.listen(
      (Uint8List chunk) {
        _bytesInLastSec += chunk.length;
        buffer.add(chunk);

        while (true) {
          final currentBytes = buffer.takeBytes();
          int offset = 0;
          final total = currentBytes.length;

          while (true) {
            if (expectedPayloadLen < 0) {
              if (total - offset < 16) break;
              // 檢查 Magic 'UDSP' (0x55, 0x44, 0x53, 0x50)
              if (currentBytes[offset] != 0x55 ||
                  currentBytes[offset + 1] != 0x44 ||
                  currentBytes[offset + 2] != 0x53 ||
                  currentBytes[offset + 3] != 0x50) {
                // 尋找下一個 'U' 同步點
                int nextU = -1;
                for (int i = offset + 1; i <= total - 4; i++) {
                  if (currentBytes[i] == 0x55 &&
                      currentBytes[i + 1] == 0x44 &&
                      currentBytes[i + 2] == 0x53 &&
                      currentBytes[i + 3] == 0x50) {
                    nextU = i;
                    break;
                  }
                }
                if (nextU == -1) {
                  offset = total;
                  break;
                } else {
                  offset = nextU;
                  if (total - offset < 16) break;
                }
              }

              final bd = ByteData.sublistView(currentBytes, offset, offset + 16);
              expectedPayloadLen = bd.getUint32(4, Endian.big);
              headerWidth = bd.getUint16(8, Endian.big);
              headerHeight = bd.getUint16(10, Endian.big);
              offset += 16;

              if (expectedPayloadLen <= 0 || expectedPayloadLen > 20 * 1024 * 1024) {
                expectedPayloadLen = -1;
                break;
              }
            }

            if (expectedPayloadLen >= 0) {
              if (total - offset < expectedPayloadLen) break;
              final frameBytes = Uint8List.fromList(
                currentBytes.sublist(offset, offset + expectedPayloadLen),
              );
              offset += expectedPayloadLen;
              expectedPayloadLen = -1;

              _srcWidth = headerWidth;
              _srcHeight = headerHeight;
              _onCompressedFrameReceived(frameBytes);
            }
          }

          if (offset < total) {
            buffer.add(Uint8List.sublistView(currentBytes, offset));
          }
          break;
        }
      },
      onDone: () => _onSocketClosed('連線已結束'),
      onError: (e) => _onSocketClosed('連線中斷: $e'),
      cancelOnError: true,
    );
  }

  void _sendHelloHandshake() {
    final sock = _activeSocket;
    if (sock == null) return;
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final pSize = view.physicalSize;
      final dpr = view.devicePixelRatio;
      final msg = jsonEncode({
        'type': 'hello',
        'platform': Platform.operatingSystem,
        'physicalWidth': pSize.width.round(),
        'physicalHeight': pSize.height.round(),
        'pixelRatio': dpr,
      });
      sock.add(utf8.encode('$msg\n'));
    } catch (_) {}
  }

  void _onCompressedFrameReceived(Uint8List jpegBytes) {
    // 回傳極短 ACK 讓 PC 端控制推流節奏，避免 USB 緩衝區塞車
    try {
      _activeSocket?.add(const [0x41, 0x43, 0x4B, 0x0A]); // "ACK\n"
    } catch (_) {}

    // 最新幀優先（Drop-stale-frame）：若 GPU 正在解上一張，直接更新待解碼佇列為最新一張
    _latestPendingBytes = jpegBytes;
    if (!_isDecoding) {
      _pumpDecoder();
    }
  }

  Future<void> _pumpDecoder() async {
    if (_isDecoding) return;
    _isDecoding = true;
    try {
      while (_latestPendingBytes != null && mounted) {
        final bytes = _latestPendingBytes!;
        _latestPendingBytes = null;

        final codec = await ui.instantiateImageCodec(bytes);
        final frameInfo = await codec.getNextFrame();
        final newImg = frameInfo.image;
        codec.dispose();

        if (!mounted) {
          newImg.dispose();
          break;
        }
        final oldImg = _frameNotifier.value;
        _frameNotifier.value = newImg;
        oldImg?.dispose();
        _framesInLastSec++;
      }
    } catch (_) {
      // 忽略單一損壞影格
    } finally {
      _isDecoding = false;
    }
  }

  void _onSocketClosed(String reason) {
    _disconnectCurrent();
    if (mounted) {
      setState(() {
        _statusText = '🔌 $reason — 等待重新插線或 PC 重新連線（埠 $kUsbListenPort）';
        _showHud = true;
      });
    }
  }

  void _disconnectCurrent() {
    try {
      _activeSocket?.destroy();
    } catch (_) {}
    _activeSocket = null;
    _isConnected = false;
    _currentFps = 0;
    _currentMbps = 0;
  }

  void _toggleHud() {
    setState(() => _showHud = !_showHud);
    if (_showHud && _isConnected) {
      _scheduleHudHide();
    }
  }

  void _scheduleHudHide() {
    _hudAutoHideTimer?.cancel();
    _hudAutoHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isConnected) {
        setState(() => _showHud = false);
      }
    });
  }

  void _setRotation(int mode) {
    setState(() => _rotationMode = mode);
    if (mode == 0) {
      SystemChrome.setPreferredOrientations([]);
    } else if (mode == 1) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    _scheduleHudHide();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final physW = (media.size.width * media.devicePixelRatio).round();
    final physH = (media.size.height * media.devicePixelRatio).round();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleHud,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 底層：第二螢幕高速渲染畫布
            ValueListenableBuilder<ui.Image?>(
              valueListenable: _frameNotifier,
              builder: (context, image, _) {
                if (image == null) {
                  return _buildStandbyDashboard(physW, physH);
                }
                return Center(
                  child: RawImage(
                    image: image,
                    fit: _boxFit,
                    width: double.infinity,
                    height: double.infinity,
                    filterQuality: FilterQuality.low,
                  ),
                );
              },
            ),

            // 2. 軟體防刺眼調暗遮罩（單向顯示時可調降亮度）
            if (_brightnessDim > 0)
              IgnorePointer(
                child: Container(
                  color: Colors.black.withOpacity(_brightnessDim),
                ),
              ),

            // 3. 頂部輕量控制列（連線中輕點畫面才出現，4 秒自動隱藏）
            if (_showHud)
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: SafeArea(
                  child: _buildFloatingHud(physW, physH),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStandbyDashboard(int physW, int physH) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E5FF).withOpacity(0.08),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.desktop_windows_rounded,
                            color: Color(0xFF00E5FF), size: 32),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'UniDisplay 跨平台第二螢幕',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '本機點對點解析度：$physW × $physH px ｜ 純單向零延遲顯示器模式',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2937),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Color(0xFF00E5FF),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _statusText,
                            style: const TextStyle(
                              color: Color(0xFF67E8F9),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    '🔌 方式一：Type-C 一線直連（自動偵測 iPad usbmuxd ／ Android ADB）',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '1. 用 Type-C 線將本裝置插上 Windows PC。\n'
                    '2. 在 PC 雙擊執行「啟動第二螢幕發送端_Windows.bat」。\n'
                    '3. PC 會自動透過 Apple usbmuxd（iPad/iPhone）或 ADB（Android）將延伸螢幕畫面送入本機埠 23456，無需任何設定！',
                    style: TextStyle(fontSize: 13.5, color: Colors.white70, height: 1.5),
                  ),
                  const Divider(height: 28, color: Colors.white24),
                  const Text(
                    '🌐 方式二：USB 網路共享 ／ 區域網路直連',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _localIps.isEmpty
                        ? [
                            const Chip(
                              label: Text('本機監聽埠：23456（等待網路介面...）'),
                            )
                          ]
                        : _localIps
                            .map((ip) => Chip(
                                  backgroundColor: const Color(0xFF0F172A),
                                  label: Text(
                                    '$ip : $kUsbListenPort',
                                    style: const TextStyle(
                                      color: Color(0xFF38BDF8),
                                      fontFamily: 'monospace',
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ))
                            .toList(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _pcIpCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '或輸入 PC 的 IP 主動連線（選填）',
                            hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: _connectingOut ? null : _connectToPcHost,
                        icon: const Icon(Icons.link, size: 18),
                        label: const Text('連向 PC'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingHud(int physW, int physH) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.78),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isConnected ? Icons.fiber_manual_record : Icons.link_off,
                color: _isConnected ? Colors.greenAccent : Colors.orangeAccent,
                size: 14,
              ),
              const SizedBox(width: 8),
              Text(
                _isConnected
                    ? '[$_peerInfo] FPS: ${_currentFps.toStringAsFixed(0)} ｜ ${_currentMbps.toStringAsFixed(1)} Mbps ｜ 來源: ${_srcWidth}x$_srcHeight ➔ 本機: ${physW}x$physH'
                    : '待機中（輕點畫面可隱藏/顯示此工具列）',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 畫面比例切換
              PopupMenuButton<BoxFit>(
                tooltip: '畫面比例模式',
                initialValue: _boxFit,
                onSelected: (fit) {
                  setState(() => _boxFit = fit);
                  _scheduleHudHide();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: BoxFit.contain,
                    child: Text('📐 等比例完整顯示 (Contain)'),
                  ),
                  PopupMenuItem(
                    value: BoxFit.cover,
                    child: Text('🖥️ 裁切填滿螢幕 (Cover)'),
                  ),
                  PopupMenuItem(
                    value: BoxFit.fill,
                    child: Text('↔️ 拉伸填滿全螢幕 (Stretch)'),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.aspect_ratio, size: 16, color: Colors.cyanAccent),
                      SizedBox(width: 4),
                      Text('比例', style: TextStyle(fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 橫直向鎖定
              InkWell(
                onTap: () => _setRotation((_rotationMode + 1) % 3),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.screen_rotation, size: 16, color: Colors.amberAccent),
                      const SizedBox(width: 4),
                      Text(
                        _rotationMode == 0
                            ? '旋轉:自動'
                            : (_rotationMode == 1 ? '旋轉:橫向' : '旋轉:直向'),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 亮度微調
              InkWell(
                onTap: () {
                  setState(() {
                    if (_brightnessDim == 0.0) {
                      _brightnessDim = 0.25;
                    } else if (_brightnessDim == 0.25) {
                      _brightnessDim = 0.5;
                    } else {
                      _brightnessDim = 0.0;
                    }
                  });
                  _scheduleHudHide();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.brightness_6, size: 16, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        '亮度:${((1.0 - _brightnessDim) * 100).round()}%',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ),
              if (_isConnected) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _onSocketClosed('手動中斷連線'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '斷開',
                      style: TextStyle(fontSize: 12.5, color: Colors.redAccent),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
