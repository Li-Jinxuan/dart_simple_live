import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/douyu/web_login_controller.dart';

class DouyuWebLoginPage extends GetView<DouyuWebLoginController> {
  const DouyuWebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("斗鱼账号登录"),
        actions: [
          TextButton.icon(
            onPressed: controller.manualCheck,
            icon: const Icon(Icons.check),
            label: const Text("完成"),
          ),
        ],
      ),
      body: Column(
        children: [
          const Material(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.grey),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                  child: Text(
                      "使用手机验证码登录斗鱼，登录后可观看2K及以上清晰度，登录完成后会自动返回。",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InAppWebView(
              onWebViewCreated: controller.onWebViewCreated,
              onLoadStop: controller.onLoadStop,
              initialSettings: InAppWebViewSettings(
                userAgent:
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
              ),
            ),
          ),
        ],
      ),
    );
  }
}
