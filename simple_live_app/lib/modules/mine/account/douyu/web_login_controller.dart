import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';

class DouyuWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();
  Timer? checkTimer;
  bool logined = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    //直接打开斗鱼passport登录页（验证码登录），登录后Cookie落在.douyu.com域
    webViewController!.loadUrl(
      urlRequest: URLRequest(
        url: WebUri(
          "https://passport.douyu.com/index/login?type=login&client_id=1&state=https%3A%2F%2Fwww.douyu.com%2F",
        ),
      ),
    );
    //轮询仅作兜底：登录Cookie由接口响应种下，正常由下面的导航事件更早检测到
    checkTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (timer) => checkLogin(),
    );
  }

  /// 登录成功后passport会跳转到斗鱼域，导航开始的瞬间Cookie已种好，
  /// 这里是事件驱动的最早检测点
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
        url: WebUri("https://www.douyu.com/"),
      );
      //acf_auth 为登录凭证，出现即说明登录成功
      var hasAuth = cookies.any((e) => e.name == "acf_auth");
      if (!hasAuth) {
        return false;
      }
      logined = true;
      checkTimer?.cancel();
      var cookieStr = cookies.map((e) => "${e.name}=${e.value}").join(";");
      Log.i("斗鱼登录成功");
      DouyuAccountService.instance.setCookie(cookieStr);
      SmartDialog.showToast("斗鱼登录成功");
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
