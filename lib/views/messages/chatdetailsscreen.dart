import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../services/app_repository.dart';
import '../../services/chat_message_store.dart';
import '../../services/chat_realtime.dart';
import '../../state/session_scope.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';

/// Conversation thread backed by Supabase chat/message queries and RPCs.
///
/// * Messages are merged by their server primary key, which is the same id the
///   client generates before sending. An optimistic bubble, the RPC response,
///   a retry and a Realtime INSERT therefore collapse into one bubble.
/// * [realtimeEvents] supplies live INSERT/UPDATE events. When it is absent
///   (tests, restricted networks) [enablePolling] keeps the thread fresh.
/// * Failed sends stay visible with an explicit retry action; nothing reports
///   success before the RPC confirms the row was stored.
class ChatDetailsScreen extends StatefulWidget {
  const ChatDetailsScreen({
    super.key,
    this.chatId = '',
    this.userName = 'Conversation',
    this.avatarUrl = 'images/c3.png',
    this.realtimeEvents,
    this.enablePolling = false,
  });

  final String chatId;
  final String userName;
  final String avatarUrl;
  final Stream<ChatRealtimeEvent>? realtimeEvents;
  final bool enablePolling;

  @override
  State<ChatDetailsScreen> createState() => _ChatDetailsScreenState();
}

class _ChatDetailsScreenState extends State<ChatDetailsScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ChatMessageStore _store = ChatMessageStore();
  final Set<String> _inFlight = <String>{};

  StreamSubscription<ChatRealtimeEvent>? _realtimeSubscription;
  Timer? _pollTimer;
  String _resolvedTitle = '';
  bool _loading = true;
  bool _live = false;
  String? _error;
  String? _syncError;
  bool _initialized = false;
  String? _activeAuthUid;
  String? _activeAppUid;
  bool _sessionReady = false;
  int _identityGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.read(context);
    final authUid = session.user?.uid;
    final appUid = session.repository.currentUid;
    final ready =
        session.isSignedIn &&
        authUid != null &&
        authUid.isNotEmpty &&
        appUid != null &&
        appUid.isNotEmpty;

    if (!_initialized) {
      _initialized = true;
      _resolvedTitle = widget.userName;
      _activeAuthUid = authUid;
      _activeAppUid = appUid;
      _sessionReady = ready;
      _subscribeRealtime();
      if (widget.enablePolling) _startPolling();
      if (ready) {
        unawaited(_loadMessages());
      } else {
        _loading = false;
        _error = 'Sign in to view messages.';
      }
      return;
    }

    if (authUid == _activeAuthUid &&
        appUid == _activeAppUid &&
        ready == _sessionReady) {
      return;
    }

    // A route can stay mounted while the auth provider signs out, changes
    // accounts, or is re-verifying a profile. Clear all per-thread state
    // before a result or Realtime event from the previous identity can render.
    _identityGeneration++;
    _activeAuthUid = authUid;
    _activeAppUid = appUid;
    _sessionReady = ready;
    _store.clear();
    _messagesView = const <Map<String, dynamic>>[];
    _messageController.clear();
    _inFlight.clear();
    _live = false;
    _syncError = null;
    _resolvedTitle = widget.userName;

    if (!ready) {
      _loading = false;
      _error =
          authUid == null
              ? 'Sign in to view messages.'
              : 'Your profile could not be verified. Please retry.';
      return;
    }

    _loading = widget.chatId.isNotEmpty;
    _error = null;
    unawaited(_loadMessages());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_realtimeSubscription?.cancel());
    _messageController.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    final stream = widget.realtimeEvents;
    if (stream == null) return;
    _realtimeSubscription = stream.listen((event) {
      if (!mounted || !_acceptRealtimeEvent(event)) return;
      switch (event.kind) {
        case ChatRealtimeEventKind.connected:
          setState(() {
            _live = true;
            _syncError = null;
          });
          break;
        case ChatRealtimeEventKind.disconnected:
          setState(() => _live = false);
          break;
        case ChatRealtimeEventKind.error:
          setState(() {
            _live = false;
            _syncError = 'Live updates are unavailable; messages still refresh automatically.';
          });
          break;
        case ChatRealtimeEventKind.record:
          _onRealtimeRecord(event);
          break;
      }
    });
  }

  bool _acceptRealtimeEvent(ChatRealtimeEvent event) {
    if (!_sessionReady ||
        (event.userId != null && event.userId != _activeAuthUid)) {
      return false;
    }
    final session = SessionScope.maybeRead(context);
    return session != null &&
        session.isSignedIn &&
        session.user?.uid == _activeAuthUid &&
        session.repository.currentUid == _activeAppUid;
  }

  void _onRealtimeRecord(ChatRealtimeEvent event) {
    final record = event.record;
    if (record == null) return;
    if (event.table == 'chat_messages' && event.changeType != 'DELETE') {
      final row = <String, dynamic>{
        'id': record['id']?.toString() ?? '',
        'chatId': record['chat_id']?.toString() ?? '',
        'senderId': record['sender_id']?.toString() ?? '',
        'senderName': record['sender_name']?.toString() ?? '',
        'text': record['text']?.toString() ?? '',
        'createdAt': record['created_at']?.toString() ?? '',
      };
      if (row['id']!.isEmpty || row['chatId'] != widget.chatId) return;
      if (_store.upsert(row)) setState(() {});
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) unawaited(_loadMessages(silent: true));
    });
  }

  Future<void> _loadMessages({bool silent = false}) async {
    if (widget.chatId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Select a conversation from Messages to view and send replies.';
      });
      return;
    }

    final session = SessionScope.read(context);
    final authUid = session.user?.uid;
    final currentUid = session.repository.currentUid;
    final generation = _identityGeneration;
    if (!_sessionReady || authUid == null || currentUid == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            authUid == null
                ? 'Sign in to view messages.'
                : 'Your profile could not be verified. Please retry.';
      });
      return;
    }
    if (!_isCurrentIdentity(
      generation: generation,
      authUid: authUid,
      appUid: currentUid,
    )) {
      return;
    }

    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final data = await session.repository.fetchChatMessages(widget.chatId);
      if (!_isCurrentIdentity(
        generation: generation,
        authUid: authUid,
        appUid: currentUid,
      )) {
        return;
      }
      final rawMessages = data['messages'];
      final history = rawMessages is List
          ? rawMessages.whereType<Map>().map((m) => Map<String, dynamic>.from(m))
          : const <Map<String, dynamic>>[];
      _store.replaceHistory(history);

      var title = widget.userName;
      final names = data['participantNames'];
      if (names is Map) {
        for (final entry in names.entries) {
          if (entry.key.toString() != currentUid &&
              entry.value != null &&
              entry.value.toString().trim().isNotEmpty) {
            title = entry.value.toString().trim();
            break;
          }
        }
      }
      setState(() {
        _messagesView = _store.items;
        _resolvedTitle = title;
        _loading = false;
        _error = null;
        _syncError = null;
      });
    } on ApiException catch (e) {
      if (!_isCurrentIdentity(
        generation: generation,
        authUid: authUid,
        appUid: currentUid,
      )) {
        return;
      }
      if (silent) {
        setState(() => _syncError = e.message);
      } else {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (!_isCurrentIdentity(
        generation: generation,
        authUid: authUid,
        appUid: currentUid,
      )) {
        return;
      }
      const message =
          'Could not load messages. Check your connection and try again.';
      if (silent) {
        setState(() => _syncError = message);
      } else {
        setState(() {
          _error = message;
          _loading = false;
        });
      }
    }
  }

  bool _isCurrentIdentity({
    required int generation,
    required String authUid,
    required String appUid,
  }) {
    if (!mounted ||
        generation != _identityGeneration ||
        !_sessionReady ||
        _activeAuthUid != authUid ||
        _activeAppUid != appUid) {
      return false;
    }
    final session = SessionScope.maybeRead(context);
    return session != null &&
        session.isSignedIn &&
        session.user?.uid == authUid &&
        session.repository.currentUid == appUid;
  }

  /// The immutable list rendered by [ListView.builder]; rebuilt only when the
  /// store actually changes.
  List<Map<String, dynamic>> _messagesView = const <Map<String, dynamic>>[];

  void _refreshView() {
    if (!mounted) return;
    setState(() => _messagesView = _store.items);
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || widget.chatId.isEmpty || _sending || !_sessionReady) {
      return;
    }

    final session = SessionScope.read(context);
    final authUid = session.user?.uid;
    final currentUid = session.repository.currentUid;
    final generation = _identityGeneration;
    if (authUid == null ||
        currentUid == null ||
        !_isCurrentIdentity(
          generation: generation,
          authUid: authUid,
          appUid: currentUid,
        )) {
      return;
    }

    final repository = session.repository;
    final clientId = repository.newClientMessageId();
    _store.addPending(
      clientId: clientId,
      chatId: widget.chatId,
      senderId: currentUid,
      senderName: session.profile?.displayName ?? 'You',
      text: text,
      createdAt: DateTime.now(),
    );
    _messageController.clear();
    _refreshView();
    await _dispatch(
      clientId,
      text,
      repository,
      authUid: authUid,
      appUid: currentUid,
      generation: generation,
    );
  }

  Future<void> _retry(String clientId) async {
    if (!_sessionReady) return;
    final row = _store.byId(clientId);
    final text = row?['text']?.toString() ?? '';
    if (text.isEmpty) return;
    final session = SessionScope.read(context);
    final authUid = session.user?.uid;
    final currentUid = session.repository.currentUid;
    final generation = _identityGeneration;
    if (authUid == null ||
        currentUid == null ||
        !_isCurrentIdentity(
          generation: generation,
          authUid: authUid,
          appUid: currentUid,
        )) {
      return;
    }

    final repository = session.repository;
    _store.addPending(
      clientId: clientId,
      chatId: widget.chatId,
      senderId: row?['senderId']?.toString() ?? currentUid,
      senderName: row?['senderName']?.toString() ?? 'You',
      text: text,
      createdAt: DateTime.tryParse(row?['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
    _refreshView();
    await _dispatch(
      clientId,
      text,
      repository,
      authUid: authUid,
      appUid: currentUid,
      generation: generation,
    );
  }

  bool get _sending => _inFlight.isNotEmpty;

  Future<void> _dispatch(
    String clientId,
    String text,
    AppRepository repository, {
    required String authUid,
    required String appUid,
    required int generation,
  }) async {
    _inFlight.add(clientId);
    _refreshView();
    try {
      final saved = await repository.sendMessage(
        chatId: widget.chatId,
        text: text,
        clientMessageId: clientId,
      );
      if (!_isCurrentIdentity(
        generation: generation,
        authUid: authUid,
        appUid: appUid,
      )) {
        return;
      }
      _store.confirm(clientId, saved);
      setState(() {
        _messagesView = _store.items;
        _syncError = null;
      });
    } on ApiException catch (e) {
      if (!_isCurrentIdentity(
        generation: generation,
        authUid: authUid,
        appUid: appUid,
      )) {
        return;
      }
      _store.markFailed(clientId);
      setState(() {
        _messagesView = _store.items;
        _syncError = e.message;
      });
    } catch (_) {
      if (!_isCurrentIdentity(
        generation: generation,
        authUid: authUid,
        appUid: appUid,
      )) {
        return;
      }
      _store.markFailed(clientId);
      setState(() {
        _messagesView = _store.items;
        _syncError = 'Message not sent. Check your connection and tap Retry.';
      });
    } finally {
      if (generation == _identityGeneration) {
        _inFlight.remove(clientId);
        _refreshView();
      }
    }
  }

  String _formatTimestamp(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return '';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final currentUid = session.repository.currentUid;

    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            if (_syncError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                color: Colors.orange.shade100,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_syncError!, style: const TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () => _loadMessages(silent: true),
                      child: const Text('Refresh'),
                    ),
                  ],
                ),
              ),
            Expanded(child: _buildBody(currentUid)),
            if (widget.chatId.isNotEmpty && _sessionReady && session.isSignedIn)
              _buildMessageInputField(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      color: AppColors.buttonColor,
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.arrow_back, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          CircleAvatar(
            radius: 22,
            backgroundImage: AssetImage(widget.avatarUrl),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text1(
                  text1: _resolvedTitle.isEmpty ? 'Conversation' : _resolvedTitle,
                  color: Colors.white,
                  size: 18,
                ),
                Row(
                  children: [
                    Icon(
                      _live ? Icons.bolt : Icons.sync,
                      size: 12,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 4),
                    Text2(
                      text2: _live ? 'Live' : 'Auto-refresh',
                      color: Colors.white70,
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _loading ? null : () => _loadMessages(),
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: 'Refresh messages',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(String? currentUid) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 46, color: AppColors.text3Color),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: AppColors.text2Color),
              ),
              if (widget.chatId.isNotEmpty) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: () => _loadMessages(), child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
    }

    if (_messagesView.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            'No messages yet. Send a message below to start the conversation.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: AppColors.text2Color),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      itemCount: _messagesView.length,
      itemBuilder: (context, index) {
        final msg = _messagesView[index];
        final senderId = msg['senderId']?.toString() ?? '';
        final isSentByMe = currentUid != null && senderId == currentUid;
        final text = msg['text']?.toString() ?? '';
        final time = _formatTimestamp(msg['timestamp'] ?? msg['createdAt']);
        final delivery = msg['delivery'] as ChatMessageDelivery? ??
            ChatMessageDelivery.sent;
        final id = msg['id']?.toString() ?? '';
        return isSentByMe
            ? _buildSentMessage(text, time, delivery, id)
            : _buildReceivedMessage(text, time);
      },
    );
  }

  Widget _buildReceivedMessage(String message, String time) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text1(text1: message, size: 15),
            if (time.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.bottomRight,
                child: Text2(text2: time, color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSentMessage(
    String message,
    String time,
    ChatMessageDelivery delivery,
    String id,
  ) {
    final failed = delivery == ChatMessageDelivery.failed;
    final sending = delivery == ChatMessageDelivery.sending;
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onTap: failed ? () => _retry(id) : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: failed ? Colors.red.shade700 : AppColors.buttonColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text1(text1: message, color: Colors.white, size: 15),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (sending)
                    const SizedBox(
                      height: 10,
                      width: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white70,
                      ),
                    )
                  else if (failed)
                    const Icon(Icons.error_outline, size: 13, color: Colors.white)
                  else
                    const Icon(Icons.done_all, size: 13, color: Colors.white70),
                  const SizedBox(width: 5),
                  Text2(
                    text2: sending
                        ? 'Sending…'
                        : failed
                            ? 'Not sent · tap to retry'
                            : time,
                    color: Colors.white70,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageInputField() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade300,
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(30),
              ),
              child: TextField(
                controller: _messageController,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: const InputDecoration(
                  hintText: 'Type your message...',
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sending ? null : _sendMessage,
            child: CircleAvatar(
              radius: 22,
              backgroundColor: _sending ? Colors.grey : AppColors.buttonColor,
              child: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}
