// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    Future.microtask(() => refreshData());
    super.onInit();
  }

  @override
  Future refreshData() async {
    currentPage = 1;
    canLoadMore.value = false;
    pageError.value = false;
    pageEmpty.value = false;
    notLogin.value = false;
    pageLoadding.value = true;
    await FollowService.instance.loadData();
    filterData();
    pageLoadding.value = false;
  }

  @override
  Future loadData() async {
    canLoadMore.value = false;
    return;
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    return FollowService.instance.liveList.value;
  }

  void filterData() {
    list.assignAll(FollowService.instance.liveList.value);
    pageEmpty.value = list.isEmpty;
  }
}
