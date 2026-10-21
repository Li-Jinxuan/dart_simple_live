import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/modules/settings/danmu_shield/danmu_shield_editor.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController
    with WidgetsBindingObserver, GetSingleTickerProviderStateMixin {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var liveStatus = false.obs;

  /// 滚动控制
  late final ScrollController scrollController = ScrollController(
    onAttach: (_) => scheduleChatScrollToBottom(resetAutoScroll: true),
  );
  late final TabController messageTabController;
  int _lastMessageTabIndex = 0;
  bool _chatScrollScheduled = false;
  bool _resetChatAutoScroll = false;

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;
  StreamSubscription<Duration>? _playbackPositionSubscription;
  Duration _lastPlaybackPosition = Duration.zero;
  bool _resumePlaybackAfterBackground = false;
  bool _recoveringPlayback = false;
  int _playbackRecoveryVersion = 0;
  Completer<void>? _playbackRecoveryReady;
  bool _danmakuConnectionHealthy = false;
  bool _danmakuReconnectNoticeShown = false;
  int _livePlayRequestVersion = 0;
  bool _closing = false;
  Future<void> _playerOperations = Future<void>.value();

  /// 直播换源和后台恢复共用同一实例，所有播放操作按顺序执行。
  Future<void> _serializePlayer(Future<void> Function() action) {
    final operation = _playerOperations.then((_) async {
      if (!isClosed && !_closing) await action();
    });
    _playerOperations = operation.catchError((Object error, StackTrace stack) {
      Log.logPrint(error);
    });
    return operation;
  }

  bool _canOpenLive(int version) =>
      !isClosed && !_closing && version == _livePlayRequestVersion;

  @override
  void onInit() {
    messageTabController = TabController(length: 3, vsync: this);
    messageTabController.addListener(_onMessageTabChanged);
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
    _playbackPositionSubscription =
        player.stream.position.listen(_onPlaybackPositionChanged);
  }

  void scrollListener() {
    if (isClosed || scrollController.positions.length != 1) {
      return;
    }
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  void _onMessageTabChanged() {
    final index = messageTabController.index;
    if (index != 0) {
      _lastMessageTabIndex = index;
      return;
    }
    if (!messageTabController.indexIsChanging && _lastMessageTabIndex != 0) {
      _lastMessageTabIndex = 0;
      scheduleChatScrollToBottom(resetAutoScroll: true);
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    _cancelPlaybackRecovery();
    //messages.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 等列表完成布局后滚动；进入聊天区域时恢复跟随最新消息。
  void scheduleChatScrollToBottom({bool resetAutoScroll = false}) {
    if (isClosed) {
      return;
    }
    _resetChatAutoScroll = _resetChatAutoScroll || resetAutoScroll;
    if (_chatScrollScheduled) {
      return;
    }
    _chatScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chatScrollScheduled = false;
      if (isClosed) {
        return;
      }
      if (messageTabController.index != 0 ||
          messageTabController.indexIsChanging) {
        _resetChatAutoScroll = false;
        return;
      }
      if (scrollController.positions.length != 1 ||
          !scrollController.position.hasContentDimensions) {
        return;
      }
      if (_resetChatAutoScroll) {
        _resetChatAutoScroll = false;
        disableAutoScroll.value = false;
      }
      chatScrollToBottom();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 跟随最新消息，手动上翻历史时暂停自动滚动。
  void chatScrollToBottom() {
    if (isClosed ||
        disableAutoScroll.value ||
        scrollController.positions.length != 1) {
      return;
    }
    final position = scrollController.position;
    if (position.hasContentDimensions &&
        position.pixels != position.maxScrollExtent) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    _danmakuConnectionHealthy = false;
    _danmakuReconnectNoticeShown = false;
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        keyword = keyword.trim();
        if (keyword.isEmpty) {
          continue;
        }
        if (msg.message.contains(keyword)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      scheduleChatScrollToBottom();
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
    scheduleChatScrollToBottom();
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    if (_danmakuConnectionHealthy) {
      _danmakuConnectionHealthy = false;
    }

    if (_danmakuReconnectNoticeShown) {
      return;
    }

    _danmakuReconnectNoticeShown = true;
    addSysMsg("弹幕服务器连接失败，正在重试");
  }

  /// WebSocket准备就绪
  void onWSReady() {
    _danmakuConnectionHealthy = true;
    _danmakuReconnectNoticeShown = false;
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  Future<void> loadData() async {
    final version = ++_livePlayRequestVersion;
    final liveSite = site.liveSite;
    final room = roomId;
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      final roomDetail = await liveSite.getRoomDetail(roomId: room);
      if (!_canOpenLive(version)) return;
      detail.value = roomDetail;

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          rxRoomId.value = detail.value!.roomId;
        }
      }

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      if (isClosed || _closing || version != _livePlayRequestVersion) return;
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e is Error ? e : StateError(e.toString());
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  Future<void> getPlayQualites() async {
    _cancelPlaybackRecovery();
    final version = ++_livePlayRequestVersion;
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);
      if (!_canOpenLive(version)) return;

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (!_canOpenLive(version)) return;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      await getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      if (_canOpenLive(version)) SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<void> getPlayUrl() async {
    _cancelPlaybackRecovery();
    final version = ++_livePlayRequestVersion;
    if (currentQuality < 0 ||
        currentQuality >= qualites.length ||
        detail.value == null) {
      return;
    }
    try {
      playUrls.clear();
      currentQualityInfo.value = qualites[currentQuality].quality;
      currentLineInfo.value = "";
      currentLineIndex = -1;
      var playUrl = await site.liveSite.getPlayUrls(
          detail: detail.value!, quality: qualites[currentQuality]);
      if (!_canOpenLive(version)) return;
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        return;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      currentLineIndex = 0;
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      //重置错误次数
      mediaErrorRetryCount = 0;
      await initPlaylist();
    } catch (error) {
      Log.logPrint(error);
      if (_canOpenLive(version)) SmartDialog.showToast('无法读取播放地址');
    }
  }

  void changePlayLine(int index) {
    if (index < 0 || index >= playUrls.length) return;
    _cancelPlaybackRecovery();
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<void> initPlaylist() async {
    final version = _livePlayRequestVersion;
    final lineIndex = currentLineIndex;
    if (!_canOpenLive(version) || lineIndex < 0 || lineIndex >= playUrls.length)
      return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    await _serializePlayer(() async {
      if (!_canOpenLive(version)) return;
      await initializePlayer();
      if (!_canOpenLive(version)) return;
      await player.open(Playlist(mediaList, index: lineIndex));
    });
  }

  Future<void> setPlayer() async {
    final version = _livePlayRequestVersion;
    final lineIndex = currentLineIndex;
    if (lineIndex < 0 || lineIndex >= playUrls.length) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    await _serializePlayer(() async {
      if (!_canOpenLive(version)) return;
      if (_canOpenLive(version)) await player.jump(lineIndex);
    });
  }

  /// 以进度实际前进确认恢复，避免把重试请求当成已经恢复播放。
  void _onPlaybackPositionChanged(Duration position) {
    if (isClosed) {
      return;
    }
    final advancing = position > _lastPlaybackPosition;
    _lastPlaybackPosition = position;
    final state = player.state;
    if (!advancing || !state.playing || state.buffering || state.completed) {
      return;
    }
    mediaErrorRetryCount = 0;
    liveStatus.value = true;
    errorMsg.value = "";
    final ready = _playbackRecoveryReady;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
  }

  void _cancelPlaybackRecovery() {
    _playbackRecoveryVersion++;
    _recoveringPlayback = false;
    final ready = _playbackRecoveryReady;
    _playbackRecoveryReady = null;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
  }

  bool _isCurrentPlaybackRecovery(int version, String siteId, String room) {
    return !isClosed &&
        !isBackground &&
        version == _playbackRecoveryVersion &&
        site.id == siteId &&
        roomId == room;
  }

  /// 后台旧连接失效时，重新获取房间、清晰度和地址，再确认播放真正恢复。
  Future<void> _recoverPlaybackAfterBackground() async {
    if (isClosed || isBackground || _recoveringPlayback) {
      return;
    }
    final version = ++_playbackRecoveryVersion;
    _livePlayRequestVersion++;
    final siteId = site.id;
    final room = roomId;
    final liveSite = site.liveSite;
    final previousQuality = currentQualityInfo.value;
    final previousLine = currentLineIndex;
    _recoveringPlayback = true;
    errorMsg.value = "";
    addSysMsg("正在恢复直播播放");

    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
          return;
        }
        Completer<void>? ready;
        try {
          await _serializePlayer(() async {
            if (_isCurrentPlaybackRecovery(version, siteId, room)) {
              await player.stop();
            }
          });
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          final roomDetail = await liveSite.getRoomDetail(roomId: room);
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          if (!roomDetail.status && !roomDetail.isRecord) {
            detail.value = roomDetail;
            liveStatus.value = false;
            return;
          }
          final qualities = await liveSite.getPlayQualites(detail: roomDetail);
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          if (qualities.isEmpty) {
            throw StateError("无法读取播放清晰度");
          }
          var qualityIndex = qualities
              .indexWhere((quality) => quality.quality == previousQuality);
          if (qualityIndex < 0) {
            final qualityLevel = await getQualityLevel();
            qualityIndex = qualityLevel == 2
                ? 0
                : qualityLevel == 0
                    ? qualities.length - 1
                    : qualities.length ~/ 2;
          }
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          final playUrl = await liveSite.getPlayUrls(
            detail: roomDetail,
            quality: qualities[qualityIndex],
          );
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          if (playUrl.urls.isEmpty) {
            throw StateError("无法读取播放地址");
          }

          detail.value = roomDetail;
          online.value = roomDetail.online;
          qualites.value = qualities;
          currentQuality = qualityIndex;
          currentQualityInfo.value = qualities[qualityIndex].quality;
          playUrls.value = playUrl.urls;
          playHeaders = playUrl.headers;
          currentLineIndex =
              previousLine >= 0 && previousLine < playUrl.urls.length
                  ? previousLine
                  : 0;

          await liveDanmaku.stop();
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          initDanmau();
          await liveDanmaku.start(roomDetail.danmakuData);
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          ready = Completer<void>();
          _playbackRecoveryReady = ready;
          _lastPlaybackPosition = Duration.zero;
          await initPlaylist();
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          await ready.future.timeout(const Duration(seconds: 15));
          if (_isCurrentPlaybackRecovery(version, siteId, room)) {
            startLiveDurationTimer();
          }
          return;
        } catch (e) {
          Log.logPrint(e);
          if (!_isCurrentPlaybackRecovery(version, siteId, room)) {
            return;
          }
          if (attempt == 2) {
            errorMsg.value = "播放恢复失败";
            SmartDialog.showToast("播放恢复失败，请刷新直播间");
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        } finally {
          if (identical(_playbackRecoveryReady, ready)) {
            _playbackRecoveryReady = null;
          }
        }
      }
    } finally {
      if (version == _playbackRecoveryVersion) {
        _recoveringPlayback = false;
      }
    }
  }

  @override
  void mediaEnd() async {
    super.mediaEnd();
    if (_closing) return;
    final recoveryVersion = _playbackRecoveryVersion;
    if (isClosed || isBackground || _recoveringPlayback) {
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      if (isClosed ||
          isBackground ||
          _recoveringPlayback ||
          recoveryVersion != _playbackRecoveryVersion) {
        return;
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    super.mediaError(error);
    if (_closing) return;
    final recoveryVersion = _playbackRecoveryVersion;
    if (isClosed || isBackground || _recoveringPlayback) {
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      if (isClosed ||
          isBackground ||
          _recoveringPlayback ||
          recoveryVersion != _playbackRecoveryVersion) {
        return;
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: const DanmuShieldEditor(),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    _cancelPlaybackRecovery();
    _livePlayRequestVersion++;
    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await _serializePlayer(() async {
      await player.stop();
    });

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error?.stackTrace}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      if (Platform.isAndroid || Platform.isIOS) {
        _resumePlaybackAfterBackground = player.state.playing ||
            player.state.buffering ||
            _recoveringPlayback;
        _cancelPlaybackRecovery();
      }
      isBackground = true;
      danmakuController?.pause();
      danmakuController?.clear();
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
      danmakuController?.resume();
      if (_resumePlaybackAfterBackground) {
        _resumePlaybackAfterBackground = false;
        unawaited(_recoverPlaybackAfterBackground());
      }
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    _closing = true;
    _livePlayRequestVersion++;
    _cancelPlaybackRecovery();
    WidgetsBinding.instance.removeObserver(this);
    _playbackPositionSubscription?.cancel();
    messageTabController.removeListener(_onMessageTabChanged);
    messageTabController.dispose();
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    autoExitTimer?.cancel();

    _danmakuConnectionHealthy = false;
    _danmakuReconnectNoticeShown = false;
    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
