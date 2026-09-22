import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class HuyaAccountService extends GetxService {
  static HuyaAccountService get instance => Get.find<HuyaAccountService>();

  var cookie = "";
  var logined = false.obs;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaCookie, "");
    logined.value = cookie.contains("udb_passport") && cookie.contains("udb_uid");
    name.value = getNickName();
    super.onInit();
  }

  /// 从Cookie中解析用户名
  String getNickName() {
    if (!logined.value) {
      return "未登录";
    }
    try {
      var match = RegExp(r"username=([^;]+)").firstMatch(cookie);
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
    LocalStorageService.instance.setValue(LocalStorageService.kHuyaCookie, cookie);
    logined.value = cookie.contains("udb_passport") && cookie.contains("udb_uid");
    name.value = getNickName();
  }

  void logout() async {
    cookie = "";
    logined.value = false;
    name.value = "未登录";
    LocalStorageService.instance.setValue(LocalStorageService.kHuyaCookie, "");
    //清除WebView中的登录态，避免下次打开直接恢复登录
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isWindows) {
        var cookieManager = CookieManager.instance();
        await cookieManager.deleteCookies(
          url: WebUri("https://www.huya.com/"),
        );
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 上次成功拉取的关注列表缓存
  /// 无头WebView偶发拉取失败（返回未登录壳）时用于保底，避免列表突然清空
  List<FollowUser> lastFollowList = [];

  /// 拉取虎牙官方关注列表（需登录）
  /// 虎牙"我的关注"为SSR页面且只对真实文档导航返回登录态数据
  /// （脚本请求/Dio直连一律返回未登录壳，已实测），
  /// 因此用无头WebView做真实导航后从DOM提取关注条目
  Future<List<FollowUser>> fetchFollowList() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      var (result, loginShell) = await _fetchFromWebView();
      if (!loginShell && result.isNotEmpty) {
        lastFollowList = result;
        return result;
      }
      if (loginShell && attempt == 0) {
        //偶发拿到未登录壳，重试一次
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      if (loginShell) {
        Log.logPrint("虎牙关注列表拉取失败（未登录壳），使用上次缓存");
        return lastFollowList;
      }
      //页面正常但无条目（全部未开播等），返回空
      return result;
    }
    return lastFollowList;
  }

  /// 无头WebView导航拉取，返回 (关注列表, 是否未登录壳)
  Future<(List<FollowUser>, bool)> _fetchFromWebView() async {
    var result = <FollowUser>[];
    var loginShell = false;
    HeadlessInAppWebView? headless;
    var completer = Completer<void>();
    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri("https://www.huya.com/myfollow"),
        ),
        initialSettings: InAppWebViewSettings(
          userAgent:
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
        ),
        onLoadStop: (controller, url) async {
          try {
            //SSR数据随HTML到达，轮询几次等待渲染完成
            for (var i = 0; i < 8; i++) {
              var json = await controller.evaluateJavascript(source: """
                (() => {
                  const items = [...document.querySelectorAll('li.subscribe-live-item')];
                  return JSON.stringify({
                    loginShell: document.body.innerText.includes('(请登录)'),
                    items: items.map(li => {
                      const img = li.querySelector('img.pic');
                      const href = (li.querySelector('a[href]') || {}).pathname || '';
                      return {
                        roomId: href.replace(/^\\//, '') || li.dataset.lp || '',
                        name: img ? (img.alt || '').replace('的直播', '') : '',
                        live: !!li.querySelector('.tag-living'),
                        cover: img ? (img.src || '') : '',
                      };
                    }),
                  });
                })()
              """);
              if (json != null) {
                var parsed = jsonDecode(json.toString()) as Map;
                loginShell = parsed["loginShell"] == true;
                var list = (parsed["items"] as List?) ?? [];
                if (list.isNotEmpty || loginShell) {
                  for (var element in list) {
                    var e = element as Map;
                    var roomId = e["roomId"]?.toString() ?? "";
                    if (roomId.isEmpty) continue;
                    var user = FollowUser(
                      id: "huya_$roomId",
                      roomId: roomId,
                      siteId: Constant.kHuya,
                      userName: e["name"]?.toString() ?? roomId,
                      face: e["cover"]?.toString() ?? "",
                      addTime: DateTime.now(),
                    );
                    user.liveStatus.value = e["live"] == true ? 2 : 1;
                    result.add(user);
                  }
                  break;
                }
              }
              await Future.delayed(const Duration(milliseconds: 500));
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
      await completer.future.timeout(const Duration(seconds: 25));
    } catch (e) {
      Log.logPrint(e);
    } finally {
      try {
        await headless?.dispose();
      } catch (_) {}
    }
    return (result, loginShell);
  }
}
