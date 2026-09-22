import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyinAccountService extends GetxService {
  static DouyinAccountService get instance => Get.find<DouyinAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  /// 抖音登录状态（sessionid存在即为已登录）
  var logined = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    logined.value = cookie.contains("sessionid");
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite);
    //登录后的完整Cookie包含ttwid；未登录时自定义ttwid或内置默认值由核心库处理
    site.cookie = cookie;
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, cookie);
    hasCookie.value = cookie.isNotEmpty;
    logined.value = cookie.contains("sessionid");
    setSite();
  }

  void clearCookie() async {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = false;
    logined.value = false;
    setSite();
    //清除WebView中的登录态，避免下次打开直接恢复登录
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isWindows) {
        var cookieManager = CookieManager.instance();
        await cookieManager.deleteCookies(
          url: WebUri("https://www.douyin.com/"),
        );
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 拉取抖音直播关注列表（需登录）
  /// 抖音"我的关注"仅显示正在直播的主播，此接口与其行为一致；
  /// 接口无需签名参数（已实测），条目自带房间号/昵称/头像/热度/标题
  Future<List<FollowUser>> fetchFollowList() async {
    var result = <FollowUser>[];
    try {
      var resp = await HttpClient.instance.getJson(
        "https://live.douyin.com/webcast/web/feed/follow/",
        queryParameters: {
          "device_platform": "webapp",
          "aid": 6383,
          "channel": "channel_pc_web",
          "scene": "aweme_pc_follow_top",
          "update_version_code": 170400,
          "pc_client_type": 2,
          "support_h265": 0,
          "support_dash": 0,
        },
        header: {
          "Cookie": cookie,
          "user-agent":
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
          "referer": "https://live.douyin.com/",
        },
      );
      var data = resp["data"] as Map? ?? {};
      //返回结构有两种形态：{"data":[...]}列表 或 {"0":{...},"1":{...}}索引，均需兼容
      var entries = <Map>[];
      if (data["data"] is List) {
        for (var e in data["data"] as List) {
          if (e is Map) entries.add(e);
        }
      } else {
        for (var v in data.values) {
          if (v is Map) entries.add(v);
        }
      }
      for (var value in entries) {
        var roomId = value["web_rid"]?.toString() ?? "";
        if (roomId.isEmpty) continue;
        //两种返回形态：列表形态条目在room字段，索引形态在data字段
        var detail = (value["room"] as Map?) ?? (value["data"] as Map?) ?? {};
        var owner = (detail["owner"] as Map?) ?? {};
        var userName = owner["nickname"]?.toString() ?? roomId;
        var face = "";
        var avatarThumb =
            (owner["avatar_thumb"] as Map?) ?? (owner["avatar_medium"] as Map?);
        if (avatarThumb != null) {
          var urlList = avatarThumb["url_list"] as List?;
          if (urlList != null && urlList.isNotEmpty) {
            face = urlList.first.toString();
          }
        }
        var user = FollowUser(
          id: "douyin_$roomId",
          roomId: roomId,
          siteId: Constant.kDouyin,
          userName: userName,
          face: face,
          addTime: DateTime.now(),
        );
        //feed只返回正在直播的主播
        user.liveStatus.value = 2;
        user.online = int.tryParse(
                ((detail["stats"] as Map?)?["user_count_str"] ?? "0").toString()) ??
            0;
        result.add(user);
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return result;
  }
}
