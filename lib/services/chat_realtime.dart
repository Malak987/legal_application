import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Supplies one app-wide Realtime connection. Screens that are rendered in
/// tests without this scope fall back to polling instead of opening a socket.
class ChatRealtimeScope extends InheritedWidget {
  const ChatRealtimeScope({
    super.key,
    required this.service,
    required super.child,
  });

  final ChatRealtimeService service;

  static ChatRealtimeService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatRealtimeScope>()?.service;

  @override
  bool updateShouldNotify(covariant ChatRealtimeScope oldWidget) =>
      oldWidget.service != service;
}

/// Creates a Phoenix-compatible socket. Kept injectable so widget/unit tests
/// never open a real network connection.
typedef ChatSocketFactory = WebSocketChannel Function(Uri uri);

typedef ChatRealtimeTokenProvider = Future<String?> Function(String? userId);

enum ChatRealtimeEventKind { connected, disconnected, record, error }

/// One decoded Supabase Realtime notification.
class ChatRealtimeEvent {
  const ChatRealtimeEvent._({
    required this.kind,
    this.table,
    this.changeType,
    this.record,
    this.message,
    this.userId,
  });

  factory ChatRealtimeEvent.connected({String? userId}) =>
      ChatRealtimeEvent._(
        kind: ChatRealtimeEventKind.connected,
        userId: userId,
      );
  factory ChatRealtimeEvent.disconnected({String? userId}) =>
      ChatRealtimeEvent._(
        kind: ChatRealtimeEventKind.disconnected,
        userId: userId,
      );
  factory ChatRealtimeEvent.error(String message, {String? userId}) =>
      ChatRealtimeEvent._(
        kind: ChatRealtimeEventKind.error,
        message: message,
        userId: userId,
      );
  factory ChatRealtimeEvent.record({
    required String table,
    required String changeType,
    required Map<String, dynamic> record,
    String? userId,
  }) => ChatRealtimeEvent._(
    kind: ChatRealtimeEventKind.record,
    table: table,
    changeType: changeType,
    record: record,
    userId: userId,
  );

  final ChatRealtimeEventKind kind;
  final String? table;
  final String? changeType;
  final Map<String, dynamic>? record;
  final String? message;

  /// Auth user who owned the socket when this event was received. It lets
  /// screens discard queued events from a previous account after a switch.
  final String? userId;

  ChatRealtimeEvent forUser(String? userId) => ChatRealtimeEvent._(
    kind: kind,
    table: table,
    changeType: changeType,
    record: record,
    message: message,
    userId: userId,
  );
}

/// Minimal Supabase Realtime (Phoenix) client for `chats` and `chat_messages`.
///
/// * The public publishable key goes in the URL, the caller's short-lived Auth
///   JWT goes in the `phx_join` payload. No service-role key is ever used.
/// * RLS is evaluated by Realtime with that JWT, so a subscriber only receives
///   rows from conversations they are a participant in.
/// * If Realtime is unavailable, the caller's polling fallback keeps working;
///   this class never substitutes mock data and never reports fake success.
class ChatRealtimeService {
  ChatRealtimeService({
    required this.baseUrl,
    required this.anonKey,
    required this.tokenProvider,
    ChatSocketFactory? socketFactory,
    this.heartbeatInterval = const Duration(seconds: 25),
    this.retryBaseDelay = const Duration(seconds: 2),
    this.connectionTimeout = const Duration(seconds: 20),
  }) : _socketFactory = socketFactory ?? _defaultSocket;

  final String baseUrl;
  final String anonKey;
  final ChatRealtimeTokenProvider tokenProvider;
  final ChatSocketFactory _socketFactory;
  final Duration heartbeatInterval;
  final Duration retryBaseDelay;
  final Duration connectionTimeout;

  final StreamController<ChatRealtimeEvent> _events =
      StreamController<ChatRealtimeEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _joinTimeout;
  Timer? _retry;
  final Set<String> _pendingJoinRefs = <String>{};
  final Map<String, String> _joinRefsByTopic = <String, String>{};
  final Map<String, String> _joinTopicsByRef = <String, String>{};
  int _ref = 0;
  int _attempt = 0;
  int _connectionId = 0;
  int _sessionGeneration = 0;
  String? _userId;
  String? _activeToken;
  bool _connecting = false;
  bool _connectRequested = false;
  bool _isConnected = false;
  bool _disposed = false;

  Stream<ChatRealtimeEvent> get events => _events.stream;
  bool get isConnected => _isConnected;

  static WebSocketChannel _defaultSocket(Uri uri) =>
      WebSocketChannel.connect(uri);

  /// Parses one raw Phoenix frame. Exposed for tests; returns `null` for
  /// heartbeats, join acknowledgements and malformed frames.
  static Map<String, dynamic>? _decodeFrame(Object? raw) {
    if (raw == null) return null;
    dynamic decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    if (decoded is! Map) return null;
    try {
      return Map<String, dynamic>.from(decoded);
    } on TypeError {
      return null;
    }
  }

  static ChatRealtimeEvent? parse(Object? raw) {
    final decoded = _decodeFrame(raw);
    if (decoded == null) return null;
    final event = decoded['event']?.toString();
    final payload = decoded['payload'];
    if (event == 'phx_reply' && payload is Map) {
      final status = payload['status']?.toString();
      if (status == 'error') {
        return ChatRealtimeEvent.error(
          (payload['response'] is Map
                      ? (payload['response']['reason'] ??
                          payload['response']['message'])
                      : null)
                  ?.toString() ??
              'Realtime subscription was rejected.',
        );
      }
      return null;
    }
    if (event != 'postgres_changes' || payload is! Map) return null;
    final data = payload['data'];
    if (data is! Map) return null;
    final record = data['record'];
    if (record is! Map) return null;
    return ChatRealtimeEvent.record(
      table: data['table']?.toString() ?? '',
      changeType: data['type']?.toString() ?? 'INSERT',
      record: Map<String, dynamic>.from(record),
    );
  }

  Uri get websocketUri {
    final base = Uri.parse(baseUrl);
    final scheme = base.scheme == 'http' ? 'ws' : 'wss';
    return base.replace(
      scheme: scheme,
      path: '/realtime/v1/websocket',
      queryParameters: <String, String>{'apikey': anonKey, 'vsn': '1.0.0'},
    );
  }

  /// Binds the app-wide connection to the currently verified account.
  ///
  /// A user change always closes the previous socket. A same-user token refresh
  /// updates healthy joined channels with the Phoenix `access_token` event;
  /// only a channel that has not successfully joined is recreated.
  Future<void> setSession(String? userId) async {
    if (_disposed) return;
    final trimmed = userId?.trim();
    final nextUid = trimmed == null || trimmed.isEmpty ? null : trimmed;

    if (nextUid == null) {
      if (_userId == null &&
          _channel == null &&
          !_connecting &&
          _retry == null) {
        return;
      }
      final previousUserId = _userId;
      _sessionGeneration++;
      _userId = null;
      _activeToken = null;
      _connectRequested = false;
      _retry?.cancel();
      _retry = null;
      _attempt = 0;
      final wasConnected = _isConnected;
      _resetChannel();
      if (wasConnected) {
        _events.add(ChatRealtimeEvent.disconnected(userId: previousUserId));
      }
      return;
    }

    if (_userId != nextUid) {
      final previousUserId = _userId;
      _sessionGeneration++;
      _userId = nextUid;
      _activeToken = null;
      _retry?.cancel();
      _retry = null;
      _attempt = 0;
      final wasConnected = _isConnected;
      _resetChannel();
      if (wasConnected) {
        _events.add(ChatRealtimeEvent.disconnected(userId: previousUserId));
      }
      await _requestConnect();
      return;
    }

    final generation = ++_sessionGeneration;
    if (_isConnected && _channel != null && _pendingJoinRefs.isEmpty) {
      String? token;
      try {
        token = await tokenProvider(nextUid).timeout(connectionTimeout);
      } catch (_) {
        return;
      }
      if (_disposed ||
          generation != _sessionGeneration ||
          _userId != nextUid ||
          token == null ||
          token.isEmpty ||
          token == _activeToken) {
        return;
      }
      if (_pushAccessToken(token)) _activeToken = token;
      return;
    }

    _retry?.cancel();
    _retry = null;
    _resetChannel();
    await _requestConnect();
  }

  Future<void> _requestConnect() {
    if (_disposed) return Future<void>.value();
    if (_connecting) {
      _connectRequested = true;
      return Future<void>.value();
    }
    return connect();
  }

  Future<void> connect() async {
    if (_disposed || _channel != null || _connecting) return;
    _connecting = true;
    _retry?.cancel();
    _retry = null;
    final generation = _sessionGeneration;
    final userId = _userId;
    WebSocketChannel? channel;
    try {
      final token = await tokenProvider(userId).timeout(connectionTimeout);
      if (!_isCurrentSession(generation, userId)) return;
      if (token == null || token.isEmpty) {
        _scheduleReconnect();
        return;
      }

      channel = _socketFactory(websocketUri);
      final connectionId = ++_connectionId;
      _channel = channel;
      _activeToken = token;
      _isConnected = false;
      _pendingJoinRefs.clear();
      _joinRefsByTopic.clear();
      _joinTopicsByRef.clear();

      // web_socket_channel 3.x reports handshake failures through `ready`.
      // No join is sent until that handshake has completed.
      await channel.ready.timeout(connectionTimeout);
      if (!_isCurrentSession(generation, userId) ||
          connectionId != _connectionId ||
          !identical(_channel, channel)) {
        if (!identical(_channel, channel)) {
          try {
            unawaited(channel.sink.close());
          } catch (_) {}
        }
        return;
      }

      _subscription = channel.stream.listen(
        (raw) {
          if (connectionId == _connectionId) _handleFrame(raw);
        },
        onError: (Object _) {
          if (_disposed || connectionId != _connectionId) return;
          _events.add(
            ChatRealtimeEvent.error(
              'Realtime connection failed. Retrying…',
              userId: _userId,
            ),
          );
          if (_isConnected) {
            _events.add(ChatRealtimeEvent.disconnected(userId: _userId));
          }
          _resetChannel();
          _scheduleReconnect();
        },
        onDone: () {
          if (_disposed || connectionId != _connectionId) return;
          if (_isConnected) {
            _events.add(ChatRealtimeEvent.disconnected(userId: _userId));
          }
          _resetChannel();
          _scheduleReconnect();
        },
      );
      _join('realtime:public:chat_messages', 'INSERT', token);
      _join('realtime:public:chats', 'UPDATE', token);
      if (_channel != null) {
        if (_pendingJoinRefs.isNotEmpty) {
          _joinTimeout?.cancel();
          _joinTimeout = Timer(connectionTimeout, () {
            if (_disposed ||
                connectionId != _connectionId ||
                !_isCurrentSession(generation, userId) ||
                !identical(_channel, channel) ||
                _pendingJoinRefs.isEmpty) {
              return;
            }
            _events.add(
              ChatRealtimeEvent.error(
                'Realtime subscription timed out. Retrying…',
                userId: _userId,
              ),
            );
            if (_isConnected) {
              _events.add(ChatRealtimeEvent.disconnected(userId: _userId));
            }
            _resetChannel();
            _scheduleReconnect();
          });
        }
        _heartbeat = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
      }
    } catch (_) {
      if (!_disposed && _isCurrentSession(generation, userId)) {
        _events.add(
          ChatRealtimeEvent.error(
            'Realtime connection failed. Retrying…',
            userId: _userId,
          ),
        );
        _resetChannel();
        _scheduleReconnect();
      } else if (channel != null && !identical(_channel, channel)) {
        try {
          unawaited(channel.sink.close());
        } catch (_) {}
      }
    } finally {
      _connecting = false;
      if (_connectRequested && !_disposed) {
        _connectRequested = false;
        unawaited(_requestConnect());
      }
    }
  }

  bool _isCurrentSession(int generation, String? userId) =>
      !_disposed && generation == _sessionGeneration && _userId == userId;

  void _handleFrame(Object? raw) {
    if (_disposed) return;
    final frame = _decodeFrame(raw);
    if (frame == null) return;
    final payload = frame['payload'];
    final frameEvent = frame['event']?.toString();

    if (frameEvent == 'phx_reply' && payload is Map) {
      final status = payload['status']?.toString();
      if (status == 'ok') {
        final ref = frame['ref']?.toString();
        final topic = frame['topic']?.toString();
        final expectedTopic = ref == null ? null : _joinTopicsByRef[ref];
        if (ref != null &&
            topic == expectedTopic &&
            _pendingJoinRefs.remove(ref)) {
          _joinTopicsByRef.remove(ref);
          if (_pendingJoinRefs.isEmpty &&
              _joinRefsByTopic.length == 2 &&
              _channel != null &&
              !_isConnected) {
            _joinTimeout?.cancel();
            _joinTimeout = null;
            _isConnected = true;
            _attempt = 0;
            _events.add(ChatRealtimeEvent.connected(userId: _userId));
          }
        }
        return;
      }
      if (status == 'error') {
        final event = parse(frame);
        if (event != null) _events.add(event.forUser(_userId));
        if (_isConnected) {
          _events.add(ChatRealtimeEvent.disconnected(userId: _userId));
        }
        _resetChannel();
        _scheduleReconnect();
        return;
      }
    }

    if (frameEvent == 'phx_error' || frameEvent == 'phx_close') {
      final reason =
          payload is Map
              ? (payload['reason'] ?? payload['message'])?.toString()
              : null;
      _events.add(
        ChatRealtimeEvent.error(
          reason?.isNotEmpty == true
              ? reason!
              : 'Realtime authorization changed. Reconnecting…',
          userId: _userId,
        ),
      );
      if (_isConnected) {
        _events.add(ChatRealtimeEvent.disconnected(userId: _userId));
      }
      _resetChannel();
      _scheduleReconnect();
      return;
    }

    final event = parse(frame);
    if (event != null) _events.add(event.forUser(_userId));
  }

  void _join(String topic, String change, String token) {
    if (_channel == null) return;
    final ref = '${++_ref}';
    _pendingJoinRefs.add(ref);
    _joinRefsByTopic[topic] = ref;
    _joinTopicsByRef[ref] = topic;
    _send(<String, dynamic>{
      'topic': topic,
      'event': 'phx_join',
      'payload': <String, dynamic>{
        'config': <String, dynamic>{
          'broadcast': <String, dynamic>{'self': false},
          'presence': <String, dynamic>{'key': ''},
          'postgres_changes': <Map<String, dynamic>>[
            <String, dynamic>{
              'event': change,
              'schema': 'public',
              'table': topic.split(':').last,
            },
          ],
        },
        'access_token': token,
      },
      'ref': ref,
      'join_ref': ref,
    });
  }

  bool _pushAccessToken(String token) {
    if (!_isConnected || _channel == null || _joinRefsByTopic.isEmpty) {
      return false;
    }
    for (final entry in _joinRefsByTopic.entries) {
      if (!_send(<String, dynamic>{
        'topic': entry.key,
        'event': 'access_token',
        'payload': <String, dynamic>{'access_token': token},
        'ref': '${++_ref}',
        'join_ref': entry.value,
      })) {
        return false;
      }
    }
    return true;
  }

  void _sendHeartbeat() {
    _send(<String, dynamic>{
      'topic': 'phoenix',
      'event': 'heartbeat',
      'payload': <String, dynamic>{},
      'ref': '${++_ref}',
      'join_ref': null,
    });
  }

  bool _send(Map<String, dynamic> frame) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(jsonEncode(frame));
      return true;
    } catch (_) {
      if (_isConnected) {
        _events.add(ChatRealtimeEvent.disconnected(userId: _userId));
      }
      _resetChannel();
      _scheduleReconnect();
      return false;
    }
  }

  void _resetChannel() {
    _connectionId++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _joinTimeout?.cancel();
    _joinTimeout = null;
    _subscription?.cancel();
    _subscription = null;
    _pendingJoinRefs.clear();
    _joinRefsByTopic.clear();
    _joinTopicsByRef.clear();
    _activeToken = null;
    _isConnected = false;
    final channel = _channel;
    _channel = null;
    try {
      channel?.sink.close();
    } catch (_) {
      // The socket may already be gone; disconnect handling is unchanged.
    }
  }

  void _scheduleReconnect() {
    if (_disposed ||
        (_sessionGeneration > 0 && _userId == null) ||
        _retry?.isActive == true) {
      return;
    }
    final generation = _sessionGeneration;
    final userId = _userId;
    _attempt = (_attempt + 1).clamp(1, 5);
    final delay = Duration(
      milliseconds: retryBaseDelay.inMilliseconds * _attempt,
    );
    _retry = Timer(delay, () {
      _retry = null;
      if (_isCurrentSession(generation, userId)) {
        unawaited(_requestConnect());
      }
    });
  }

  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    _userId = null;
    _connectRequested = false;
    _retry?.cancel();
    _retry = null;
    _resetChannel();
    unawaited(_events.close());
  }
}
