// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/follow_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  /// 筛选标签：直播中 / 未开播 / 全部
  var filterMode = FollowUserTag(id: "1", tag: "直播中", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
    FollowUserTag(id: "0", tag: "全部", userId: []),
  ].obs;

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
    if (filterMode.value.tag == "全部") {
      return FollowService.instance.followList.value;
    } else if (filterMode.value.tag == "直播中") {
      return FollowService.instance.liveList.value;
    } else {
      return FollowService.instance.notLiveList.value;
    }
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  void filterData() {
    if (filterMode.value.tag == "全部") {
      list.assignAll(FollowService.instance.followList.value);
    } else if (filterMode.value.tag == "直播中") {
      list.assignAll(FollowService.instance.liveList.value);
    } else {
      list.assignAll(FollowService.instance.notLiveList.value);
    }
    pageEmpty.value = list.isEmpty;
  }
}
