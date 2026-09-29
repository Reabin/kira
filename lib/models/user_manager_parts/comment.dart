part of '../user_manager.dart';

// 屏蔽判定（isCommentUserBlocked / isCommentBlockedByWord / isCommentGroupSpam）
// 与屏蔽用户写入（blockCommentUser / setCommentBlockNoRemind）已上移到
// UserManager 类体，便于测试假体覆写；此处保留其余屏蔽词/黑名单管理入口。

extension UserManagerCommentPart on UserManager {
  Future<void> unblockCommentUser(String rawKey) async {
    _commentBlockedUsers = _commentBlockedUsers
        .where((e) => e != rawKey)
        .toList(growable: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      UserManager._keyCommentBlockedUsers,
      _commentBlockedUsers,
    );
    _notifyListeners();
  }

  Future<void> clearCommentBlockedUsers() async {
    _commentBlockedUsers = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(UserManager._keyCommentBlockedUsers);
    _notifyListeners();
  }

  Future<void> setCommentBlockwords(List<String> list) async {
    _commentBlockwords = List.from(list);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      UserManager._keyCommentBlockwords,
      _commentBlockwords,
    );
    _notifyListeners();
  }

  Future<void> addCommentBlockword(String word) async {
    final trimmed = word.trim();
    if (trimmed.isEmpty || _commentBlockwords.contains(trimmed)) return;
    _commentBlockwords = [..._commentBlockwords, trimmed];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      UserManager._keyCommentBlockwords,
      _commentBlockwords,
    );
    _notifyListeners();
  }

  Future<void> removeCommentBlockword(String word) async {
    _commentBlockwords = _commentBlockwords
        .where((e) => e != word)
        .toList(growable: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      UserManager._keyCommentBlockwords,
      _commentBlockwords,
    );
    _notifyListeners();
  }

  Future<void> clearCommentBlockwords() async {
    _commentBlockwords = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(UserManager._keyCommentBlockwords);
    _notifyListeners();
  }

  Future<void> setCommentBlockGroupSpam(bool value) async {
    _commentBlockGroupSpam = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(UserManager._keyCommentBlockGroupSpam, value);
    _notifyListeners();
  }
}
