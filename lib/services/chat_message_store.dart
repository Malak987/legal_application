/// UI state for one conversation.
///
/// The server row id is the dedup key. Because `rpc_chat_send_message` uses the
/// client-generated id as the primary key, an optimistic bubble, a successful
/// RPC response, a retry and a Realtime INSERT all carry the SAME id and merge
/// into exactly one bubble.
enum ChatMessageDelivery { sending, sent, failed }

class ChatMessageStore {
  final Map<String, Map<String, dynamic>> _byId = <String, Map<String, dynamic>>{};

  static const String _deliveryKey = 'delivery';

  List<Map<String, dynamic>> get items => _sorted();

  bool get isEmpty => _byId.isEmpty;

  /// Drops all rows when the owning account or conversation changes.
  void clear() => _byId.clear();

  /// Replaces the server-visible history while keeping unsent/failed bubbles,
  /// so a reload or a Realtime refresh never loses a message being composed.
  void replaceHistory(Iterable<Map<String, dynamic>> rows) {
    final transient = <Map<String, dynamic>>[
      for (final row in _byId.values)
        if (row[_deliveryKey] != ChatMessageDelivery.sent) row,
    ];
    _byId.clear();
    for (final row in rows) {
      _put(<String, dynamic>{...row, _deliveryKey: ChatMessageDelivery.sent});
    }
    for (final row in transient) {
      _byId.putIfAbsent(row['id']?.toString() ?? '', () => row);
    }
  }

  /// Adds the optimistic bubble for a send that has not been acknowledged.
  Map<String, dynamic> addPending({
    required String clientId,
    required String chatId,
    required String senderId,
    required String senderName,
    required String text,
    required DateTime createdAt,
  }) {
    final row = <String, dynamic>{
      'id': clientId,
      'chatId': chatId,
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'createdAt': createdAt.toUtc().toIso8601String(),
      _deliveryKey: ChatMessageDelivery.sending,
    };
    _byId[clientId] = row;
    return row;
  }

  /// Confirms a pending bubble with the authoritative server row.
  ///
  /// On a legacy server that returns a different generated id, the optimistic
  /// bubble is removed rather than left behind as a duplicate.
  void confirm(String clientId, Map<String, dynamic> serverRow) {
    final serverId = serverRow['id']?.toString() ?? '';
    if (serverId.isNotEmpty && serverId != clientId) {
      _byId.remove(clientId);
    }
    _put(<String, dynamic>{...serverRow, _deliveryKey: ChatMessageDelivery.sent});
  }

  void markFailed(String clientId) {
    final row = _byId[clientId];
    if (row == null) return;
    _byId[clientId] = <String, dynamic>{
      ...row,
      _deliveryKey: ChatMessageDelivery.failed,
    };
  }

  ChatMessageDelivery deliveryOf(String clientId) =>
      _byId[clientId]?[_deliveryKey] as ChatMessageDelivery? ??
      ChatMessageDelivery.sent;

  /// Merges one server/Realtime row. Returns true when the visible list
  /// changed, so callers avoid needless rebuilds.
  bool upsert(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    if (id.isEmpty) return false;
    final existing = _byId[id];
    if (existing != null &&
        existing[_deliveryKey] == ChatMessageDelivery.sent &&
        existing['text'] == row['text'] &&
        existing['createdAt'] == row['createdAt']) {
      return false;
    }
    _put(<String, dynamic>{...row, _deliveryKey: ChatMessageDelivery.sent});
    return true;
  }

  Map<String, dynamic>? byId(String id) => _byId[id];

  void _put(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    if (id.isNotEmpty) _byId[id] = row;
  }

  List<Map<String, dynamic>> _sorted() {
    final rows = _byId.values.toList(growable: false);
    rows.sort((a, b) {
      final aTime = DateTime.tryParse(a['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = DateTime.tryParse(b['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final byTime = aTime.compareTo(bTime);
      if (byTime != 0) return byTime;
      return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
    });
    return rows;
  }
}
