import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  static const String kWebUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0";

  var cookie = "";
  var logined = false.obs;
  var name = "未登录".obs;

  /// 上次Cookie续期时间
  DateTime? lastCookieRefresh;

  /// 续期进行中标记（防止并发起多个无头WebView）
  bool cookieRefreshing = false;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    logined.value = cookie.contains("acf_auth");
    name.value = getNickName();
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyu]!.liveSite as DouyuSite);
    site.cookie = cookie;
  }

  /// 从Cookie中解析昵称
  String getNickName() {
    if (!logined.value) {
      return "未登录";
    }
    try {
      var match = RegExp(r"acf_nickname=([^;]+)").firstMatch(cookie);
      if (match != null) {
        return Uri.decodeComponent(match.group(1)!);
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return "已登录";
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance.setValue(LocalStorageService.kDouyuCookie, cookie);
    logined.value = cookie.contains("acf_auth");
    name.value = getNickName();
    setSite();
  }

  /// 拉取斗鱼官方关注列表（需登录）
  /// 返回纯运行时的 FollowUser 列表，不写入本地数据库；
  /// 直播状态/热度/开播时间随接口返回，无需逐房间查询
  /// Cookie续期：斗鱼登录态靠页面访问滚动续期（网页版经常打开可半年不掉），
  /// App存的是静态快照，需要定期用无头WebView真实访问一次页面触发续期后重新捕获，
  /// 否则快照会在几天内过期
  Future<void> refreshCookieIfNeeded() async {
    if (!logined.value || cookieRefreshing) {
      return;
    }
    var last = lastCookieRefresh;
    if (last != null && DateTime.now().difference(last).inHours < 6) {
      return;
    }
    cookieRefreshing = true;
    HeadlessInAppWebView? headless;
    var completer = Completer<void>();
    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri("https://www.douyu.com/directory/myFollow"),
        ),
        initialSettings: InAppWebViewSettings(
          userAgent: kWebUserAgent,
        ),
        onLoadStop: (controller, url) async {
          try {
            //稍等让页面的passport校验/续期流程完成
            await Future.delayed(const Duration(seconds: 1));
            var cookies = await CookieManager.instance().getCookies(
              url: WebUri("https://www.douyu.com/"),
            );
            var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join(";");
            if (cookieStr.contains("acf_auth")) {
              setCookie(cookieStr);
              Log.i("斗鱼Cookie已续期");
            } else {
              Log.logPrint("斗鱼Cookie续期失败：未获取到acf_auth，会话可能已失效");
            }
          } catch (e) {
            Log.logPrint(e);
          } finally {
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        },
      );
      await headless.run();
      await completer.future.timeout(const Duration(seconds: 20));
      lastCookieRefresh = DateTime.now();
    } catch (e) {
      Log.logPrint(e);
    } finally {
      cookieRefreshing = false;
      try {
        await headless?.dispose();
      } catch (_) {}
    }
  }

  Future<List<FollowUser>> fetchFollowList() async {
    //拉取前先检查Cookie是否需要续期
    await refreshCookieIfNeeded();
    var result = <FollowUser>[];
    try {
      int offset = 0;
      int total = -1;
      while (total < 0 || result.length < total) {
        var resp = await HttpClient.instance.getJson(
          "https://www.douyu.com/wgapi/livenc/liveweb/follow/list",
          queryParameters: {
            "sort": 0,
            "cid1": 0,
            "limit": 100,
            "offset": offset,
          },
          header: {
            "Cookie": cookie,
            "referer": "https://www.douyu.com/directory/myFollow",
            "user-agent":
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
          },
        );
        if (resp["error"] != 0) {
          var msg = resp["msg"]?.toString() ?? "";
          Log.logPrint("斗鱼关注列表获取失败: ${resp["error"]} $msg");
          //登录态失效时清除登录状态（接口返回"未登陆"，注意兼容"登陆/登录"两种写法）
          if (msg.contains("登") || msg.contains("过期")) {
            SmartDialog.showToast("斗鱼登录已失效，请重新登录");
            logout();
          }
          break;
        }
        var data = resp["data"] as Map? ?? {};
        total = int.tryParse(data["total"].toString()) ?? 0;
        var list = (data["list"] as List?) ?? [];
        if (list.isEmpty) {
          break;
        }
        for (var item in list) {
          var roomId = item["room_id"].toString();
          var isLive = item["show_status"] == 1 && item["videoLoop"] != 1;
          var user = FollowUser(
            id: "douyu_$roomId",
            roomId: roomId,
            siteId: Constant.kDouyu,
            userName: item["nickname"]?.toString() ?? roomId,
            face: item["avatar_small"]?.toString() ?? "",
            addTime: DateTime.now(),
          );
          user.liveStatus.value = isLive ? 2 : 1;
          user.liveStartTime = isLive ? item["show_time"]?.toString() : null;
          user.online = parseOnline(item["online"]?.toString());
          result.add(user);
        }
        if (list.length < 100) {
          break;
        }
        offset += 100;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return result;
  }

  /// 解析斗鱼热度文本（如 "455.4万"、"1.2亿"）为数字
  int parseOnline(String? text) {
    if (text == null || text.isEmpty) {
      return 0;
    }
    try {
      var s = text.trim();
      if (s.contains("亿")) {
        return (double.parse(s.replaceAll("亿", "")) * 100000000).round();
      }
      if (s.contains("万")) {
        return (double.parse(s.replaceAll("万", "")) * 10000).round();
      }
      return int.tryParse(s) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  void logout() async {
    cookie = "";
    logined.value = false;
    name.value = "未登录";
    setSite();
    LocalStorageService.instance.setValue(LocalStorageService.kDouyuCookie, "");
    //清除WebView中的登录态，避免下次打开直接恢复登录
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isWindows) {
        var cookieManager = CookieManager.instance();
        await cookieManager.deleteCookies(
          url: WebUri("https://www.douyu.com/"),
        );
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }
}
