import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';

class DouyinWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();
  Timer? checkTimer;
  bool logined = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    //打开抖音个人主页，未登录会自动弹出登录面板
    webViewController!.loadUrl(
      urlRequest: URLRequest(
        url: WebUri("https://www.douyin.com/user/self"),
      ),
    );
    //轮询仅作兜底：正常由导航事件更早检测到
    checkTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (timer) => checkLogin(),
    );
  }

  /// 登录成功后Cookie落在.douyin.com域，导航开始的瞬间已种好
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
        url: WebUri("https://www.douyin.com/"),
      );
      //sessionid 为抖音登录凭证（httpOnly，CookieManager可读取）
      var hasAuth = cookies.any((e) => e.name == "sessionid");
      if (!hasAuth) {
        return false;
      }
      logined = true;
      checkTimer?.cancel();
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join(";");
      Log.i("抖音登录成功");
      DouyinAccountService.instance.setCookie(cookieStr);
      SmartDialog.showToast("抖音登录成功");
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
