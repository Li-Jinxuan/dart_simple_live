import 'dart:async';

import 'package:web_socket_channel/io.dart';

enum SocketStatus {
  connected,
  failed,
  closed,
}

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;
  bool _manuallyClosed = false;
  bool _usingBackupUrl = false;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
  });
  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数
  int reconnectTime = 0;
  Timer? reconnectTimer;

  StreamSubscription<dynamic>? streamSubscription;

  void connect({bool retry = false}) async {
    reconnectTimer?.cancel();
    reconnectTimer = null;
    _manuallyClosed = false;
    _usingBackupUrl = retry;
    _disposeActiveConnection();
    try {
      var wsurl = url;
      if (backupUrl != null && backupUrl!.isNotEmpty && retry) {
        wsurl = backupUrl!;
      }
      webSocket = IOWebSocketChannel.connect(
        wsurl,
        connectTimeout: Duration(seconds: 10),
        headers: headers,
      );

      await webSocket?.ready;
      ready();
    } catch (e) {
      onError(e, e);
      if (!_manuallyClosed) {
        reconnect();
      }
    }
  }

  /// 连接完成
  void ready() {
    status = SocketStatus.connected;

    streamSubscription = webSocket?.stream.listen(
      (data) => receiveMessage(data),
      onError: (e, s) => onError(e, s),
      onDone: onDone,
    );

    onReady?.call();
    initHeartBeat();
  }

  void initHeartBeat() {
    heartBeatTimer = Timer.periodic(
      Duration(milliseconds: heartBeatTime),
      (timer) {
        onHeartBeat?.call();
      },
    );
  }

  void receiveMessage(dynamic data) {
    //接受到一条信息才算重连成功
    reconnectTime = 0;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    onMessage?.call(data);
  }

  void onError(e, s) {
    if (_manuallyClosed) {
      return;
    }
    status = SocketStatus.failed;
    onClose?.call(e.toString());
  }

  void onDone() {
    if (status == SocketStatus.closed || _manuallyClosed) {
      return;
    }
    onReconnect?.call();
    reconnect();
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      webSocket?.sink.add(message);
    }
  }

  void close() {
    _manuallyClosed = true;
    status = SocketStatus.closed;
    reconnectTime = 0;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    _disposeActiveConnection();
  }

  void reconnect() {
    if (_manuallyClosed) {
      return;
    }
    status = SocketStatus.closed;
    reconnectTime++;
    reconnectTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_manuallyClosed) {
        timer.cancel();
        reconnectTimer = null;
        return;
      }
      final shouldTryBackup = backupUrl != null &&
          backupUrl!.isNotEmpty &&
          !_usingBackupUrl;
      connect(retry: shouldTryBackup);
    });
  }

  void _disposeActiveConnection() {
    streamSubscription?.cancel();
    streamSubscription = null;

    webSocket?.sink.close();
    webSocket = null;

    heartBeatTimer?.cancel();
    heartBeatTimer = null;
  }
}
