import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData();
    });
    initTimer();
    super.onInit();
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
            minutes:
                AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          Log.logPrint("Update Follow Timer");
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  /// 各平台最近一次拉取的结果（按平台独立槽位）
  /// 用于渐进渲染：某平台新数据到达时仅替换该平台的槽位，其余平台数据保持展示
  final Map<String, List<FollowUser>> platformResults = {};

  /// 关注列表全部来自各平台官方接口（需登录对应平台账号），
  /// 本地关注数据不再使用；登录了哪些平台就聚合显示哪些平台。
  /// 四平台并行拉取，任一平台返回后立即渲染，不必等待全部完成
  Future<void> loadData({bool updateStatus = true}) async {
    updating.value = true;
    try {
      var futures = <Future>[];
      void fetch(String siteId, Future<List<FollowUser>> Function() fetcher) {
        futures.add(Future(() async {
          var items = await fetcher();
          platformResults[siteId] = items;
          rebuildList();
        }));
      }

      //未登录的平台立即移除其旧数据
      var loginedMap = {
        Constant.kBiliBili: BiliBiliAccountService.instance.logined.value,
        Constant.kDouyu: DouyuAccountService.instance.logined.value,
        Constant.kHuya: HuyaAccountService.instance.logined.value,
        Constant.kDouyin: DouyinAccountService.instance.logined.value,
      };
      platformResults.removeWhere((siteId, _) => !loginedMap[siteId]!);
      rebuildList();

      if (loginedMap[Constant.kBiliBili]!) {
        fetch(Constant.kBiliBili,
            () => BiliBiliAccountService.instance.fetchFollowList());
      }
      if (loginedMap[Constant.kDouyu]!) {
        fetch(
            Constant.kDouyu, () => DouyuAccountService.instance.fetchFollowList());
      }
      if (loginedMap[Constant.kHuya]!) {
        fetch(
            Constant.kHuya, () => HuyaAccountService.instance.fetchFollowList());
      }
      if (loginedMap[Constant.kDouyin]!) {
        fetch(
            Constant.kDouyin, () => DouyinAccountService.instance.fetchFollowList());
      }
      if (futures.isNotEmpty) {
        await Future.wait(futures);
      }
    } finally {
      updating.value = false;
    }
  }

  /// 按各平台槽位重建总列表并刷新UI
  void rebuildList() {
    followList.assignAll(
      platformResults.values.expand((items) => items),
    );
    filterData();
  }

  void filterData() {
    followList.sort(compareFollowUsers);
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    _updatedListController.add(0);
  }

  /// 直播中优先，直播用户再按热度从高到低，最后按关注时间稳定排序。
  static int compareFollowUsers(FollowUser a, FollowUser b) {
    final statusComparison = b.liveStatus.value.compareTo(a.liveStatus.value);
    if (statusComparison != 0) {
      return statusComparison;
    }

    if (a.liveStatus.value == 2) {
      final onlineComparison = b.online.compareTo(a.online);
      if (onlineComparison != 0) {
        return onlineComparison;
      }
    }

    final addTimeComparison = a.addTime.compareTo(b.addTime);
    if (addTimeComparison != 0) {
      return addTimeComparison;
    }
    return a.id.compareTo(b.id);
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();
    super.onClose();
  }
}
