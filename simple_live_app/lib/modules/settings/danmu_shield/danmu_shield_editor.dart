import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';

class DanmuShieldEditor extends StatefulWidget {
  const DanmuShieldEditor({super.key});

  @override
  State<DanmuShieldEditor> createState() => _DanmuShieldEditorState();
}

class _DanmuShieldEditorState extends State<DanmuShieldEditor> {
  late final TextEditingController _textController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: AppSettingsController.instance.shieldList.join('\n'),
    );
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      final settings = AppSettingsController.instance;
      await settings.setShieldList(_textController.text);
      if (mounted) {
        _textController.text = settings.shieldList.join('\n');
        SmartDialog.showToast("已保存屏蔽词");
      }
    } catch (e) {
      Log.logPrint(e);
      if (mounted) {
        SmartDialog.showToast("保存失败，请重试");
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: AppStyle.edgeInsetsA12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("每行一个屏蔽词，空行和纯空白内容会自动忽略。"),
            AppStyle.vGap12,
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_saving,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                textAlignVertical: TextAlignVertical.top,
                expands: true,
                minLines: null,
                maxLines: null,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: "关键词一\n关键词二",
                ),
              ),
            ),
            AppStyle.vGap12,
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? "保存中…" : "保存"),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
}
