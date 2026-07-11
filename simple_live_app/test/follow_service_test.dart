import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/follow_service.dart';

FollowUser followUser({
  required String id,
  required DateTime addTime,
  required int status,
  int online = 0,
}) {
  return FollowUser(
    id: id,
    roomId: id,
    siteId: 'bilibili',
    userName: id,
    face: '',
    addTime: addTime,
  )
    ..liveStatus.value = status
    ..online = online;
}

void main() {
  test('直播用户按热度从高到低排序', () {
    final users = [
      followUser(
          id: 'low', addTime: DateTime(2024, 1, 3), status: 2, online: 10),
      followUser(
          id: 'high', addTime: DateTime(2024, 1, 2), status: 2, online: 100),
      followUser(
          id: 'middle', addTime: DateTime(2024, 1, 1), status: 2, online: 50),
    ];

    users.sort(FollowService.compareFollowUsers);

    expect(users.map((user) => user.id), ['high', 'middle', 'low']);
  });

  test('直播用户优先于未开播和未知状态用户', () {
    final users = [
      followUser(id: 'unknown', addTime: DateTime(2024, 1, 1), status: 0),
      followUser(id: 'offline', addTime: DateTime(2024, 1, 2), status: 1),
      followUser(
          id: 'live', addTime: DateTime(2024, 1, 3), status: 2, online: 1),
    ];

    users.sort(FollowService.compareFollowUsers);

    expect(users.map((user) => user.id), ['live', 'offline', 'unknown']);
  });

  test('标签筛选后的直播用户仍按热度和关注时间排序', () {
    final users = [
      followUser(
          id: 'newer', addTime: DateTime(2024, 1, 2), status: 2, online: 100),
      followUser(
          id: 'older', addTime: DateTime(2024, 1, 1), status: 2, online: 100),
      followUser(
          id: 'hotter', addTime: DateTime(2024, 1, 3), status: 2, online: 200),
    ];
    final service = FollowService()..followList.addAll(users);

    service.filterDataByTag(
      FollowUserTag(
          id: 'tag', tag: '测试标签', userId: ['newer', 'older', 'hotter']),
    );

    expect(
      service.curTagFollowList.map((user) => user.id),
      ['hotter', 'older', 'newer'],
    );
  });
}
