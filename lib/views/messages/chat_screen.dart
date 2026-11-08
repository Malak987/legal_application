import 'dart:async';

import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../services/chat_realtime.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import 'chatdetailsscreen.dart';

/// Conversation list backed by the caller-authorized Supabase chat query.
///
/// A client can now START a conversation: the "New message" action lists the
/// real lawyer directory and calls `rpc_chat_start_with_lawyer`, which resolves
/// the lawyer's linked application account on the server.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _searchController = TextEditingController();
  late Future<List<Map<String, dynamic>>> _chats;
  bool _loaded = false;
  String _searchQuery = '';
  String? _activeAuthUid;
  String? _activeAppUid;
  bool _sessionReady = false;
  int _identityGeneration = 0;
  Future<List<Map<String, dynamic>>>? _activeChatsRequest;
  int? _activeChatsRequestGeneration;
  bool _queuedChatsReload = false;
  ChatRealtimeService? _observedRealtime;
  StreamSubscription<ChatRealtimeEvent>? _realtimeSubscription;

  @override
  void initState() {
    super.initState();
    _chats = Future.value(const <Map<String, dynamic>>[]);
  }

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
    final identityChanged =
        !_loaded ||
        authUid != _activeAuthUid ||
        appUid != _activeAppUid ||
        ready != _sessionReady;

    if (identityChanged) {
      _loaded = true;
      _identityGeneration++;
      _queuedChatsReload = false;
      _activeAuthUid = authUid;
      _activeAppUid = appUid;
      _sessionReady = ready;
      _searchQuery = '';
      _searchController.clear();
      _chats = Future.value(const <Map<String, dynamic>>[]);
      if (ready) unawaited(_reload());
    }

    final realtime = ChatRealtimeScope.maybeOf(context);
    if (!identical(realtime, _observedRealtime)) {
      unawaited(_realtimeSubscription?.cancel());
      _observedRealtime = realtime;
      // A chat UPDATE (last_message) refreshes the list without reopening it.
      _realtimeSubscription = realtime?.events.listen((event) {
        if (event.kind != ChatRealtimeEventKind.record ||
            (event.table != 'chats' && event.table != 'chat_messages') ||
            (event.userId != null && event.userId != _activeAuthUid) ||
            !_isCurrentIdentity(
              generation: _identityGeneration,
              authUid: _activeAuthUid ?? '',
              appUid: _activeAppUid ?? '',
            )) {
          return;
        }
        _reload();
      });
    }
  }

  @override
  void dispose() {
    unawaited(_realtimeSubscription?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() {
    if (!_sessionReady || _activeAuthUid == null || _activeAppUid == null) {
      final empty = Future.value(const <Map<String, dynamic>>[]);
      if (mounted) {
        setState(() {
          _chats = empty;
        });
      } else {
        _chats = empty;
      }
      return empty.then<void>((_) {}, onError: (_) {});
    }

    final session = SessionScope.read(context);
    final authUid = _activeAuthUid!;
    final appUid = _activeAppUid!;
    final generation = _identityGeneration;
    if (!_isCurrentIdentity(
      generation: generation,
      authUid: authUid,
      appUid: appUid,
    )) {
      final empty = Future.value(const <Map<String, dynamic>>[]);
      if (mounted) {
        setState(() {
          _chats = empty;
        });
      } else {
        _chats = empty;
      }
      return empty.then<void>((_) {}, onError: (_) {});
    }

    final active = _activeChatsRequest;
    late final Future<List<Map<String, dynamic>>> future;
    if (active != null && _activeChatsRequestGeneration == generation) {
      // Coalesce bursts (especially Realtime events) into one trailing refresh.
      // The current request remains the FutureBuilder source until it settles.
      _queuedChatsReload = true;
      future = active;
    } else {
      final request = session.repository.fetchChats().then((rows) {
        if (!_isCurrentIdentity(
          generation: generation,
          authUid: authUid,
          appUid: appUid,
        )) {
          return const <Map<String, dynamic>>[];
        }
        return rows;
      });
      future = request;
      _activeChatsRequest = request;
      _activeChatsRequestGeneration = generation;
      unawaited(
        request.then<void>(
          (_) => _finishChatsRequest(
            request,
            generation: generation,
            authUid: authUid,
            appUid: appUid,
          ),
          onError: (Object _, StackTrace __) => _finishChatsRequest(
            request,
            generation: generation,
            authUid: authUid,
            appUid: appUid,
          ),
        ),
      );
    }

    if (mounted) {
      // setState callbacks must be synchronous; the Future is only stored here.
      setState(() {
        _chats = future;
      });
    } else {
      _chats = future;
    }
    return future.then<void>((_) {}, onError: (_) {});
  }

  void _finishChatsRequest(
    Future<List<Map<String, dynamic>>> request, {
    required int generation,
    required String authUid,
    required String appUid,
  }) {
    if (!identical(_activeChatsRequest, request) ||
        _activeChatsRequestGeneration != generation) {
      return;
    }

    _activeChatsRequest = null;
    _activeChatsRequestGeneration = null;
    final shouldReload = _queuedChatsReload;
    _queuedChatsReload = false;
    if (shouldReload &&
        _isCurrentIdentity(
          generation: generation,
          authUid: authUid,
          appUid: appUid,
        )) {
      unawaited(_reload());
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

  String _resolvePeerName(Map<String, dynamic> chat, String? currentUid) {
    final names = chat['participantNames'];
    if (names is Map) {
      for (final entry in names.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString().trim() ?? '';
        if (key != currentUid && value.isNotEmpty) {
          return value;
        }
      }
      for (final value in names.values) {
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) return text;
      }
    }
    return 'Legal Consultation';
  }

  String _formatTime(dynamic raw) {
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

  Future<void> _openNewConversation() async {
    if (!_sessionReady || _activeAuthUid == null || _activeAppUid == null) {
      return;
    }
    final authUid = _activeAuthUid!;
    final appUid = _activeAppUid!;
    final generation = _identityGeneration;
    if (!_isCurrentIdentity(
      generation: generation,
      authUid: authUid,
      appUid: appUid,
    )) {
      return;
    }

    final target = await showModalBottomSheet<_ChatTarget>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LawyerPickerSheet(),
    );
    if (target == null ||
        !_isCurrentIdentity(
          generation: generation,
          authUid: authUid,
          appUid: appUid,
        )) {
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailsScreen(
          chatId: target.chatId,
          userName: target.title,
          realtimeEvents: _observedRealtime?.events,
          enablePolling: true,
        ),
      ),
    );
    if (_isCurrentIdentity(
      generation: generation,
      authUid: authUid,
      appUid: appUid,
    )) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = SessionScope.of(context).repository.currentUid;

    return Scaffold(
      backgroundColor: AppColors.bgColor,
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-conversation-button'),
        onPressed: _sessionReady ? _openNewConversation : null,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New message'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Messages', text1: ''),
              const SizedBox(height: 15),
              _buildSearchBar(),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  key: ValueKey<int>(_identityGeneration),
                  future: _chats,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _ChatStatus(
                        icon: Icons.error_outline,
                        title: 'Could not load messages',
                        detail: snapshot.error is ApiException
                            ? (snapshot.error as ApiException).message
                            : 'Please try again.',
                        onRetry: _reload,
                      );
                    }

                    final allChats =
                        snapshot.data ?? const <Map<String, dynamic>>[];
                    final query = _searchQuery.trim().toLowerCase();
                    final chats = query.isEmpty
                        ? allChats
                        : allChats.where((chat) {
                            final peer =
                                _resolvePeerName(chat, currentUid).toLowerCase();
                            final last = (chat['lastMessage']?.toString() ?? '')
                                .toLowerCase();
                            return peer.contains(query) || last.contains(query);
                          }).toList();

                    if (chats.isEmpty) {
                      return _ChatStatus(
                        icon: Icons.chat_bubble_outline,
                        title: query.isEmpty
                            ? 'No conversations yet'
                            : 'No matching conversations',
                        detail: query.isEmpty
                            ? 'Tap "New message" to choose a lawyer and start a conversation.'
                            : 'Nothing matches "$_searchQuery".',
                        onRetry: query.isEmpty ? _openNewConversation : null,
                        actionLabel: query.isEmpty ? 'Choose a lawyer' : null,
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: 80),
                        itemCount: chats.length,
                        itemBuilder: (context, index) {
                          final chat = chats[index];
                          final chatId = chat['id']?.toString() ?? '';
                          final name = _resolvePeerName(chat, currentUid);
                          final lastMessage =
                              (chat['lastMessage']?.toString() ?? '').trim();
                          final time = _formatTime(
                            chat['lastMessageTime'] ?? chat['updatedAt'],
                          );
                          final contextLabel = _contextLabel(chat);

                          return GestureDetector(
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatDetailsScreen(
                                    chatId: chatId,
                                    userName: name,
                                    realtimeEvents:
                                        ChatRealtimeScope.maybeOf(context)?.events,
                                    enablePolling: true,
                                  ),
                                ),
                              );
                              if (mounted) _reload();
                            },
                            child: _buildChatTile(
                              name: name,
                              message: lastMessage.isEmpty
                                  ? (contextLabel ?? 'Tap to open conversation')
                                  : lastMessage,
                              time: time,
                              contextLabel: contextLabel,
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _contextLabel(Map<String, dynamic> chat) {
    final booking = chat['bookingId']?.toString() ?? '';
    final caseId = chat['caseId']?.toString() ?? '';
    if (booking.isNotEmpty) return 'About your appointment';
    if (caseId.isNotEmpty) return 'About your case';
    return null;
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: 'Search messages',
          border: InputBorder.none,
          icon: const Icon(Icons.search, color: Colors.grey),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildChatTile({
    required String name,
    required String message,
    required String time,
    String? contextLabel,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade100,
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 26,
            backgroundImage: AssetImage('images/c3.png'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text1(text1: name, size: 16),
                const SizedBox(height: 4),
                Text2(text2: message),
                if (contextLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      contextLabel,
                      style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                    ),
                  ),
              ],
            ),
          ),
          if (time.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text2(text2: time),
              ],
            ),
        ],
      ),
    );
  }
}

class _ChatStatus extends StatelessWidget {
  const _ChatStatus({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
    this.actionLabel,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Future<void> Function()? onRetry;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: AppColors.text3Color),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.text2Color),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onRetry,
                child: Text(actionLabel ?? 'Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The result of opening/creating a conversation.
class _ChatTarget {
  const _ChatTarget({required this.chatId, required this.title});
  final String chatId;
  final String title;
}

/// Searchable lawyer directory used to start a conversation.
class _LawyerPickerSheet extends StatefulWidget {
  const _LawyerPickerSheet();

  @override
  State<_LawyerPickerSheet> createState() => _LawyerPickerSheetState();
}

class _LawyerPickerSheetState extends State<_LawyerPickerSheet> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  List<Product> _lawyers = const <Product>[];
  bool _loading = true;
  bool _opening = false;
  String? _error;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    final query = _search.text.trim();
    final repository = SessionScope.read(context).repository;
    try {
      final lawyers = await repository.fetchLawyers(search: query);
      if (!mounted || seq != _seq) return;
      setState(() {
        _lawyers = lawyers;
        _lastQuery = query;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = 'Could not load lawyers. Check your connection and retry.';
        _loading = false;
      });
    }
  }

  Future<void> _choose(Product lawyer) async {
    final id = (lawyer.id ?? '').trim();
    if (id.isEmpty || _opening) return;
    setState(() => _opening = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chat = await SessionScope.read(context).repository.startChatWithLawyer(
            lawyerId: id,
          );
      final chatId = chat['id']?.toString() ?? '';
      if (chatId.isEmpty) {
        throw ApiException.invalidResponse('The conversation was not created.');
      }
      if (!mounted) return;
      Navigator.pop(
        context,
        _ChatTarget(chatId: chatId, title: lawyer.name.isEmpty ? 'Lawyer' : lawyer.name),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _opening = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _opening = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the conversation. Please retry.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SizedBox(
          height: 470,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Message a lawyer',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _search,
                decoration: const InputDecoration(
                  labelText: 'Search lawyers',
                  hintText: 'Name, specialty or location',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 350), _fetch);
                },
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _opening
                    ? const Center(child: CircularProgressIndicator())
                    : _buildList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _fetch, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_lawyers.isEmpty) {
      return Center(
        child: Text(
          _lastQuery.isEmpty
              ? 'No lawyers are available yet.'
              : 'No lawyers match "$_lastQuery".',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: _lawyers.length,
      itemBuilder: (context, index) {
        final lawyer = _lawyers[index];
        final details = <String>[
          if ((lawyer.specialty ?? '').trim().isNotEmpty) lawyer.specialty!.trim(),
          if ((lawyer.location ?? '').trim().isNotEmpty) lawyer.location!.trim(),
          if (lawyer.price.trim().isNotEmpty) lawyer.price.trim(),
        ];
        return ListTile(
          leading: const Icon(Icons.gavel_outlined),
          title: Text(lawyer.name.isEmpty ? 'Lawyer' : lawyer.name),
          subtitle: details.isEmpty ? null : Text(details.join('  •  ')),
          onTap: () => _choose(lawyer),
        );
      },
    );
  }
}
