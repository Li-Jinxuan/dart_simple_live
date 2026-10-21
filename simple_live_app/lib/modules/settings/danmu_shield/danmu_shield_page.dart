import 'package:flutter/material.dart';
import 'package:simple_live_app/modules/settings/danmu_shield/danmu_shield_editor.dart';

class DanmuShieldPage extends StatelessWidget {
  const DanmuShieldPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("关键词屏蔽"),
      ),
      body: const DanmuShieldEditor(),
    );
  }
}
