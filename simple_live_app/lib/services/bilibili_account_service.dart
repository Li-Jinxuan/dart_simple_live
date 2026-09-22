import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = cookie.isNotEmpty;
    loadUserInfo();
    super.onInit();
  }

  Future loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {
          "Cookie": cookie,
        },
      );
      if (result["code"] == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        setSite();
      } else {
        SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录");
        logout();
      }
    } catch (e) {
      SmartDialog.showToast("获取哔哩哔哩用户信息失败，可前往账号管理重试");
    }
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite);
    site.userId = uid;
    site.cookie = cookie;
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, cookie);
    logined.value = cookie.isNotEmpty;
  }

  /// 拉取哔哩哔哩直播关注列表（需登录）
  /// 返回纯运行时的 FollowUser 列表，不写入本地数据库；
  /// 直播状态随接口返回（无热度/开播时间字段）
  Future<List<FollowUser>> fetchFollowList() async {
    var result = <FollowUser>[];
    try {
      int page = 1;
      while (true) {
        var resp = await HttpClient.instance.getJson(
          "https://api.live.bilibili.com/xlive/web-ucenter/user/following",
          queryParameters: {
            "page": page,
            "page_size": 50,
            "ignoreRecord": 1,
            "hit_ab": true,
          },
          header: {"Cookie": cookie},
        );
        if (resp["code"] != 0) {
          Log.logPrint("哔哩哔哩关注列表获取失败: ${resp["code"]} ${resp["message"]}");
          if ((resp["message"]?.toString() ?? "").contains("登录")) {
            SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录");
            logout();
          }
          break;
        }
        var list = ((resp["data"] ?? {})["list"] as List?) ?? [];
        for (var item in list) {
          var roomId = item["roomid"]?.toString() ?? "";
          if (roomId.isEmpty || roomId == "0") {
            //未开通直播间的关注跳过
            continue;
          }
          var user = FollowUser(
            id: "bilibili_$roomId",
            roomId: roomId,
            siteId: Constant.kBiliBili,
            userName: item["uname"]?.toString() ?? roomId,
            face: item["face"]?.toString() ?? "",
            addTime: DateTime.now(),
          );
          user.liveStatus.value = item["live_status"] == 1 ? 2 : 1;
          result.add(user);
        }
        if (list.length < 50) {
          break;
        }
        page++;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return result;
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    setSite();
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = false;

    if (Platform.isAndroid || Platform.isIOS) {
      CookieManager cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();
    }
  }
}
