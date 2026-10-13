/// Login names are unique only within a source. Display names and avatars are
/// deliberately absent: neither is evidence of account ownership.
class AccountIdentity {
  final String source;
  final String username;
  final String userId;
  final String token;
  final String accountId;

  AccountIdentity({
    required this.source,
    String? username,
    String? userId,
    String? token,
    String? accountId,
  }) : username = username?.trim() ?? '',
       userId = userId?.trim() ?? '',
       token = token?.trim() ?? '',
       accountId = accountId?.trim() ?? '';

  bool matches(AccountIdentity other) {
    if (source != other.source) return false;
    if (username.isNotEmpty && other.username.isNotEmpty) {
      return username == other.username;
    }
    return (userId.isNotEmpty && userId == other.userId) ||
        (token.isNotEmpty && token == other.token) ||
        (accountId.isNotEmpty && accountId == other.accountId);
  }

  bool sharesExactCredential(AccountIdentity other) => matches(other) &&
      ((token.isNotEmpty && token == other.token) ||
       (accountId.isNotEmpty && accountId == other.accountId &&
        !accountId.startsWith('u:') && !accountId.startsWith('n:')));
}

bool _compatibleIdentities(Iterable<AccountIdentity> identities) {
  final items = identities.toList();
  if (items.map((item) => item.source).toSet().length > 1) return false;
  final names = items.map((item) => item.username)
      .where((name) => name.isNotEmpty).toSet();
  if (names.length > 1) return false;
  final userIds = items.map((item) => item.userId)
      .where((id) => id.isNotEmpty).toSet();
  if (userIds.length <= 1) return true;
  // The same confirmed login name can survive a server-id change. Anonymous
  // records cannot by themselves explain conflicting nonempty server ids.
  final namedIds = items.where((item) => item.username.isNotEmpty)
      .map((item) => item.userId).toSet();
  return names.length == 1 && namedIds.containsAll(userIds);
}

/// Merge connected, compatible identities, including anonymous bridges. Named
/// accounts are considered first so a shared fallback id cannot join two people.
/// An exact token/local handle may disambiguate a weaker shared server id; if
/// competing strong anchors remain, leave the incomplete identity separate.
List<List<T>> groupAccounts<T>(
  List<T> accounts,
  AccountIdentity Function(T) identityOf,
) {
  final groups = <List<T>>[];
  for (final named in [true, false]) {
    for (final account in accounts) {
      final identity = identityOf(account);
      if (identity.username.isNotEmpty != named) continue;
      var matches = groups.where((group) => group.any(
        (item) => identity.matches(identityOf(item)),
      )).toList();
      bool compatible(List<List<T>> candidates) => _compatibleIdentities([
        identity,
        for (final group in candidates) ...group.map(identityOf),
      ]);
      if (!compatible(matches)) {
        matches = matches.where((group) => group.any(
          (item) => identity.sharesExactCredential(identityOf(item)),
        )).toList();
      }
      if (matches.isEmpty || !compatible(matches)) {
        groups.add([account]);
        continue;
      }
      final target = matches.first;
      for (final group in matches.skip(1)) {
        target.addAll(group);
        groups.remove(group);
      }
      target.add(account);
    }
  }
  return groups;
}
