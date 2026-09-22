import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

class HuyaWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();
  Timer? checkTimer;
  bool logined = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    //打开虎牙"我的关注"页，未登录会自动弹出登录窗口
    webViewController!.loadUrl(
      urlRequest: URLRequest(
        url: WebUri("https://www.huya.com/myfollow"),
      ),
    );
    //轮询仅作兜底：正常由导航事件更早检测到
    checkTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (timer) => checkLogin(),
    );
  }

  /// 登录成功后Cookie落在.huya.com域，导航开始的瞬间已种好
  void onLoadStart(InAppWebViewController controller, Uri? uri) {
    checkLogin();
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) {
    checkLogin();
  }

  /// 手动触发检测（页面右上角"完成"按钮）
  void manualCheck() async {
    var result = await checkLogin();
    if (!result) {
      SmartDialog.showToast("未检测到登录状态，请先在页面中完成登录");
    }
  }

  Future<bool> checkLogin() async {
    if (logined) {
      return true;
    }
    try {
      var cookies = await cookieManager.getCookies(
        url: WebUri("https://www.huya.com/"),
      );
      //必须等udb_passport出现才算登录完成：
      //登录过程中udb_uid/username会先落地，若此时保存会得到残缺Cookie导致接口视为未登录
      var passport = cookies.where((e) => e.name == "udb_passport").toList();
      var uidOk = cookies.any(
        (e) => e.name == "udb_uid" && e.value.isNotEmpty && e.value != "0",
      );
      if (passport.isEmpty || !uidOk) {
        return false;
      }
      logined = true;
      checkTimer?.cancel();
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join(";");
      Log.i("虎牙登录成功");
      HuyaAccountService.instance.setCookie(cookieStr);
      SmartDialog.showToast("虎牙登录成功");
      Get.back();
      return true;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  @override
  void onClose() {
    checkTimer?.cancel();
    super.onClose();
  }
}
