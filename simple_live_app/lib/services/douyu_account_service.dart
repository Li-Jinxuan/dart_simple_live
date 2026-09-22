import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  var cookie = "";
  var logined = false.obs;
  var name = "未登录".obs;

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
