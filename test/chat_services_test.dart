// Unit tests for the mobile chat building blocks that guarantee
// "send / failure / retry / no duplicates" and Realtime frame decoding.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:legalserviceapp/services/chat_message_store.dart';
import 'package:legalserviceapp/services/chat_realtime.dart';

void main() {
  group('ChatMessageStore dedup and delivery', () {
    Map<String, dynamic> serverRow(
      String id,
      String text, {
      String time = '2026-10-28T10:00:00Z',
    }) => <String, dynamic>{
      'id': id,
      'chatId': 'chat-1',
      'senderId': 'client-1',
      'senderName': 'Client',
      'text': text,
      'createdAt': time,
    };

    test(
      'optimistic send, confirm, retry and Realtime INSERT collapse to one bubble',
      () {
        final store = ChatMessageStore();
        final pending = store.addPending(
          clientId: 'integmsg0001',
          chatId: 'chat-1',
          senderId: 'client-1',
          senderName: 'Client',
          text: 'Hello',
          createdAt: DateTime.utc(2026, 10, 28, 10),
        );
        expect(pending['delivery'], ChatMessageDelivery.sending);
        expect(store.items, hasLength(1));

        // The authoritative RPC response carries the SAME client-generated id.
        store.confirm('integmsg0001', serverRow('integmsg0001', 'Hello'));
        expect(store.deliveryOf('integmsg0001'), ChatMessageDelivery.sent);
        expect(store.items, hasLength(1));

        // A Realtime INSERT of that same row must not create a duplicate.
        expect(store.upsert(serverRow('integmsg0001', 'Hello')), isFalse);
        expect(store.items, hasLength(1));

        // A new (other) message does add a bubble, in time order.
        expect(
          store.upsert(
            serverRow('integmsg0002', 'World', time: '2026-10-28T10:01:00Z'),
          ),
          isTrue,
        );
        expect(store.items.map((r) => r['id']).toList(), [
          'integmsg0001',
          'integmsg0002',
        ]);
      },
    );

    test(
      'a legacy server id replaces the optimistic bubble instead of duplicating',
      () {
        final store = ChatMessageStore();
        store.addPending(
          clientId: 'clientlocal0001',
          chatId: 'chat-1',
          senderId: 'client-1',
          senderName: 'Client',
          text: 'Hi',
          createdAt: DateTime.utc(2026, 10, 28, 10),
        );
        store.confirm('clientlocal0001', serverRow('server-uuid-1', 'Hi'));
        expect(store.items, hasLength(1));
        expect(store.items.single['id'], 'server-uuid-1');
        expect(store.byId('clientlocal0001'), isNull);
      },
    );

    test(
      'a failed send stays visible and can be retried without a duplicate',
      () {
        final store = ChatMessageStore();
        store.addPending(
          clientId: 'retryme0001',
          chatId: 'chat-1',
          senderId: 'client-1',
          senderName: 'Client',
          text: 'Retry me',
          createdAt: DateTime.utc(2026, 10, 28, 10),
        );
        store.markFailed('retryme0001');
        expect(store.deliveryOf('retryme0001'), ChatMessageDelivery.failed);
        expect(store.items, hasLength(1));

        // replaceHistory (a reload) must not drop the failed bubble.
        store.replaceHistory([
          serverRow('othermsg0001', 'Earlier', time: '2026-10-28T09:00:00Z'),
        ]);
        expect(store.items, hasLength(2));
        expect(store.deliveryOf('retryme0001'), ChatMessageDelivery.failed);

        // Retrying with the SAME client id (idempotent RPC) confirms one bubble.
        store.confirm('retryme0001', serverRow('retryme0001', 'Retry me'));
        expect(
          store.items.where((r) => r['id'] == 'retryme0001'),
          hasLength(1),
        );
        expect(store.deliveryOf('retryme0001'), ChatMessageDelivery.sent);
      },
    );

    test('replaceHistory keeps sending bubbles but drops stale sent rows', () {
      final store = ChatMessageStore();
      store.upsert(serverRow('oldrow00001', 'stale'));
      store.addPending(
        clientId: 'pending00001',
        chatId: 'chat-1',
        senderId: 'client-1',
        senderName: 'Client',
        text: 'composing',
        createdAt: DateTime.utc(2026, 10, 28, 11),
      );
      store.replaceHistory([serverRow('freshrow0001', 'fresh')]);
      final ids = store.items.map((r) => r['id']).toSet();
      expect(ids, contains('pending00001'));
      expect(ids, contains('freshrow0001'));
      expect(ids, isNot(contains('oldrow00001')));
    });

    test('upsert ignores empty ids and returns false for unchanged rows', () {
      final store = ChatMessageStore();
      expect(store.upsert(<String, dynamic>{'text': 'no id'}), isFalse);
      expect(store.upsert(serverRow('m1', 'x')), isTrue);
      expect(store.upsert(serverRow('m1', 'x')), isFalse);
      expect(store.upsert(serverRow('m1', 'edited')), isTrue);
      expect(store.items.single['text'], 'edited');
    });

    test('clear removes sent, pending, and failed rows for a new identity', () {
      final store = ChatMessageStore();
      store.upsert(serverRow('sent-1', 'private history'));
      store.addPending(
        clientId: 'pending-1',
        chatId: 'chat-1',
        senderId: 'client-1',
        senderName: 'Client',
        text: 'private draft',
        createdAt: DateTime.utc(2026, 10, 28, 11),
      );
      store.markFailed('pending-1');

      store.clear();

      expect(store.isEmpty, isTrue);
      expect(store.items, isEmpty);
      expect(store.byId('sent-1'), isNull);
      expect(store.byId('pending-1'), isNull);
    });
  });

  group('ChatRealtimeService frame parsing', () {
    test('parses a postgres_changes INSERT into a record event', () {
      final event = ChatRealtimeService.parse(<String, dynamic>{
        'event': 'postgres_changes',
        'payload': <String, dynamic>{
          'data': <String, dynamic>{
            'table': 'chat_messages',
            'type': 'INSERT',
            'record': <String, dynamic>{
              'id': 'm1',
              'chat_id': 'chat-1',
              'text': 'hi',
            },
          },
        },
      });
      expect(event, isNotNull);
      expect(event!.kind, ChatRealtimeEventKind.record);
      expect(event.table, 'chat_messages');
      expect(event.changeType, 'INSERT');
      expect(event.record!['text'], 'hi');
    });

    test('accepts a JSON string frame', () {
      final event = ChatRealtimeService.parse(
        '{"event":"postgres_changes","payload":{"data":{"table":"chats",'
        '"type":"UPDATE","record":{"id":"chat-1"}}}}',
      );
      expect(event, isNotNull);
      expect(event!.changeType, 'UPDATE');
      expect(event.table, 'chats');
    });

    test('ignores heartbeats, join acks and malformed frames', () {
      expect(ChatRealtimeService.parse(null), isNull);
      expect(ChatRealtimeService.parse('not json'), isNull);
      expect(
        ChatRealtimeService.parse(<String, dynamic>{
          'event': 'phx_reply',
          'payload': <String, dynamic>{'status': 'ok'},
        }),
        isNull,
      );
      expect(
        ChatRealtimeService.parse(<String, dynamic>{'event': 'heartbeat'}),
        isNull,
      );
      expect(
        ChatRealtimeService.parse(<String, dynamic>{
          'event': 'postgres_changes',
          'payload': <String, dynamic>{},
        }),
        isNull,
      );
      expect(ChatRealtimeService.parse(42), isNull);
    });

    test('a rejected phx_reply becomes an error event', () {
      final event = ChatRealtimeService.parse(<String, dynamic>{
        'event': 'phx_reply',
        'payload': <String, dynamic>{
          'status': 'error',
          'response': <String, dynamic>{'reason': 'Unauthorized'},
        },
      });
      expect(event, isNotNull);
      expect(event!.kind, ChatRealtimeEventKind.error);
      expect(event.message, 'Unauthorized');
    });

    test('join rejection resets and retries with a fresh auth token', () async {
      final sockets = <_FakeRealtimeSocket>[];
      final events = <ChatRealtimeEvent>[];
      final retrySocketCreated = Completer<void>();
      var tokenCalls = 0;
      final service = ChatRealtimeService(
        baseUrl: 'https://example.supabase.co',
        anonKey: 'public-anon-key',
        tokenProvider:
            (userId) async =>
                ++tokenCalls == 1 ? 'expired-token' : 'fresh-token',
        socketFactory: (_) {
          final socket = _FakeRealtimeSocket();
          sockets.add(socket);
          if (sockets.length == 2 && !retrySocketCreated.isCompleted) {
            retrySocketCreated.complete();
          }
          return socket;
        },
        heartbeatInterval: const Duration(hours: 1),
        retryBaseDelay: const Duration(milliseconds: 5),
      );
      final subscription = service.events.listen(events.add);

      await service.connect();
      expect(sockets, hasLength(1));
      expect(service.isConnected, isFalse);
      final firstJoin = sockets.first.joinFrames.first;
      expect(firstJoin['payload']['access_token'], 'expired-token');
      final rejectedRef = firstJoin['ref'].toString();
      sockets.first.addFrame(<String, dynamic>{
        'topic': firstJoin['topic'],
        'event': 'phx_reply',
        'payload': <String, dynamic>{
          'status': 'error',
          'response': <String, dynamic>{'reason': 'JWT expired'},
        },
        'ref': rejectedRef,
        'join_ref': rejectedRef,
      });

      await retrySocketCreated.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(
        events.where((event) => event.kind == ChatRealtimeEventKind.error),
        hasLength(1),
      );
      expect(sockets, hasLength(2));
      expect(tokenCalls, 2);
      final retryJoins = sockets.last.joinFrames;
      expect(retryJoins, hasLength(2));
      expect(
        retryJoins.every(
          (frame) => frame['payload']['access_token'] == 'fresh-token',
        ),
        isTrue,
      );

      // One accepted table join is not enough to report the connection as
      // ready; both subscriptions must acknowledge successfully.
      final firstRetryJoin = retryJoins.first;
      sockets.last.addFrame(<String, dynamic>{
        'topic': firstRetryJoin['topic'],
        'event': 'phx_reply',
        'payload': <String, dynamic>{
          'status': 'ok',
          'response': <String, dynamic>{},
        },
        'ref': firstRetryJoin['ref'],
        'join_ref': firstRetryJoin['join_ref'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(service.isConnected, isFalse);
      expect(
        events.where((event) => event.kind == ChatRealtimeEventKind.connected),
        isEmpty,
      );

      final secondRetryJoin = retryJoins.last;
      sockets.last.addFrame(<String, dynamic>{
        'topic': secondRetryJoin['topic'],
        'event': 'phx_reply',
        'payload': <String, dynamic>{
          'status': 'ok',
          'response': <String, dynamic>{},
        },
        'ref': secondRetryJoin['ref'],
        'join_ref': secondRetryJoin['join_ref'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(service.isConnected, isTrue);
      expect(
        events.where((event) => event.kind == ChatRealtimeEventKind.connected),
        hasLength(1),
      );

      await subscription.cancel();
      service.dispose();
    });

    test(
      'missing join acknowledgments time out and reconnect with a fresh token',
      () async {
        final sockets = <_FakeRealtimeSocket>[];
        final events = <ChatRealtimeEvent>[];
        final retrySocketCreated = Completer<void>();
        var tokenCalls = 0;
        final service = ChatRealtimeService(
          baseUrl: 'https://example.supabase.co',
          anonKey: 'public-anon-key',
          tokenProvider: (userId) async => 'jwt-${++tokenCalls}',
          socketFactory: (_) {
            final socket = _FakeRealtimeSocket();
            sockets.add(socket);
            if (sockets.length == 2 && !retrySocketCreated.isCompleted) {
              retrySocketCreated.complete();
            }
            return socket;
          },
          heartbeatInterval: const Duration(hours: 1),
          retryBaseDelay: const Duration(milliseconds: 5),
          connectionTimeout: const Duration(milliseconds: 50),
        );
        final subscription = service.events.listen(events.add);

        await service.connect();
        expect(sockets, hasLength(1));
        expect(service.isConnected, isFalse);
        await retrySocketCreated.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);

        expect(sockets, hasLength(2));
        expect(tokenCalls, 2);
        expect(
          sockets.last.joinFrames.every(
            (frame) => frame['payload']['access_token'] == 'jwt-2',
          ),
          isTrue,
        );
        expect(
          events.where(
            (event) =>
                event.kind == ChatRealtimeEventKind.error &&
                event.message!.contains('subscription timed out'),
          ),
          hasLength(1),
        );
        expect(
          events.where(
            (event) => event.kind == ChatRealtimeEventKind.connected,
          ),
          isEmpty,
        );

        await subscription.cancel();
        service.dispose();
      },
    );

    test(
      'same-user token refresh updates both joined channels in place',
      () async {
        final sockets = <_FakeRealtimeSocket>[];
        final requestedUids = <String?>[];
        var tokenCalls = 0;
        final service = ChatRealtimeService(
          baseUrl: 'https://example.supabase.co',
          anonKey: 'public-anon-key',
          tokenProvider: (userId) async {
            requestedUids.add(userId);
            return ++tokenCalls == 1 ? 'initial-jwt' : 'refreshed-jwt';
          },
          socketFactory: (_) {
            final socket = _FakeRealtimeSocket();
            sockets.add(socket);
            return socket;
          },
          heartbeatInterval: const Duration(hours: 1),
          retryBaseDelay: const Duration(hours: 1),
        );
        final events = <ChatRealtimeEvent>[];
        final subscription = service.events.listen(events.add);

        await service.setSession('user-a');
        expect(sockets, hasLength(1));
        final socket = sockets.single;
        final joins = socket.joinFrames;
        expect(joins, hasLength(2));
        expect(
          joins.every(
            (frame) => frame['payload']['access_token'] == 'initial-jwt',
          ),
          isTrue,
        );
        for (final join in joins) {
          socket.addFrame(<String, dynamic>{
            'topic': join['topic'],
            'event': 'phx_reply',
            'payload': <String, dynamic>{
              'status': 'ok',
              'response': <String, dynamic>{},
            },
            'ref': join['ref'],
            'join_ref': join['join_ref'],
          });
        }
        await Future<void>.delayed(Duration.zero);
        expect(service.isConnected, isTrue);

        await service.setSession('user-a');
        expect(
          sockets,
          hasLength(1),
          reason: 'a healthy socket must be retained',
        );
        final tokenFrames = socket.sentFrames
            .map(jsonDecode)
            .whereType<Map>()
            .map((frame) => Map<String, dynamic>.from(frame))
            .where((frame) => frame['event'] == 'access_token')
            .toList(growable: false);
        expect(tokenFrames, hasLength(2));
        expect(
          tokenFrames.every(
            (frame) => frame['payload']['access_token'] == 'refreshed-jwt',
          ),
          isTrue,
        );
        expect(
          tokenFrames.map((frame) => frame['join_ref']).toSet(),
          joins.map((frame) => frame['join_ref']).toSet(),
        );
        expect(requestedUids, ['user-a', 'user-a']);
        expect(
          events.where(
            (event) => event.kind == ChatRealtimeEventKind.connected,
          ),
          hasLength(1),
        );

        await subscription.cancel();
        service.dispose();
      },
    );

    test('account switching and logout discard the previous socket', () async {
      final sockets = <_FakeRealtimeSocket>[];
      final service = ChatRealtimeService(
        baseUrl: 'https://example.supabase.co',
        anonKey: 'public-anon-key',
        tokenProvider: (userId) async => 'jwt-$userId',
        socketFactory: (_) {
          final socket = _FakeRealtimeSocket();
          sockets.add(socket);
          return socket;
        },
        heartbeatInterval: const Duration(hours: 1),
        retryBaseDelay: const Duration(milliseconds: 5),
      );
      final events = <ChatRealtimeEvent>[];
      final subscription = service.events.listen(events.add);

      Future<void> acknowledgeAll(_FakeRealtimeSocket socket) async {
        for (final join in socket.joinFrames) {
          socket.addFrame(<String, dynamic>{
            'topic': join['topic'],
            'event': 'phx_reply',
            'payload': <String, dynamic>{
              'status': 'ok',
              'response': <String, dynamic>{},
            },
            'ref': join['ref'],
            'join_ref': join['join_ref'],
          });
        }
        await Future<void>.delayed(Duration.zero);
      }

      await service.setSession('user-a');
      final firstSocket = sockets.single;
      expect(
        firstSocket.joinFrames.every(
          (frame) => frame['payload']['access_token'] == 'jwt-user-a',
        ),
        isTrue,
      );
      await acknowledgeAll(firstSocket);
      expect(service.isConnected, isTrue);
      expect(
        events
            .where((event) => event.kind == ChatRealtimeEventKind.connected)
            .single
            .userId,
        'user-a',
      );

      await service.setSession('user-b');
      await Future<void>.delayed(Duration.zero);
      expect(sockets, hasLength(2));
      expect(service.isConnected, isFalse);
      expect(
        events.where(
          (event) => event.kind == ChatRealtimeEventKind.disconnected,
        ).last.userId,
        'user-a',
      );
      firstSocket.addFrame(<String, dynamic>{
        'event': 'postgres_changes',
        'payload': <String, dynamic>{
          'data': <String, dynamic>{
            'table': 'chat_messages',
            'type': 'INSERT',
            'record': <String, dynamic>{'id': 'late', 'chat_id': 'chat-1'},
          },
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        events.where((event) => event.kind == ChatRealtimeEventKind.record),
        isEmpty,
      );
      expect(
        sockets.last.joinFrames.every(
          (frame) => frame['payload']['access_token'] == 'jwt-user-b',
        ),
        isTrue,
      );
      await acknowledgeAll(sockets.last);
      expect(service.isConnected, isTrue);

      final beforeLogout = sockets.length;
      await service.setSession(null);
      expect(service.isConnected, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        sockets,
        hasLength(beforeLogout),
        reason: 'logout must stop retries',
      );
      expect(
        events.where(
          (event) => event.kind == ChatRealtimeEventKind.disconnected,
        ),
        hasLength(2),
      );

      await subscription.cancel();
      service.dispose();
    });

    test('late token for a prior account cannot open its socket', () async {
      final firstToken = Completer<String?>();
      final requestedUids = <String?>[];
      final sockets = <_FakeRealtimeSocket>[];
      final secondSocketCreated = Completer<void>();
      final service = ChatRealtimeService(
        baseUrl: 'https://example.supabase.co',
        anonKey: 'public-anon-key',
        tokenProvider: (userId) {
          requestedUids.add(userId);
          return userId == 'user-a'
              ? firstToken.future
              : Future.value('jwt-user-b');
        },
        socketFactory: (_) {
          final socket = _FakeRealtimeSocket();
          sockets.add(socket);
          if (!secondSocketCreated.isCompleted && sockets.length == 1) {
            secondSocketCreated.complete();
          }
          return socket;
        },
        heartbeatInterval: const Duration(hours: 1),
        retryBaseDelay: const Duration(hours: 1),
      );

      final openingA = service.setSession('user-a');
      await Future<void>.delayed(Duration.zero);
      expect(requestedUids, ['user-a']);
      expect(sockets, isEmpty);

      await service.setSession('user-b');
      firstToken.complete('jwt-user-a');
      await openingA;
      await secondSocketCreated.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(requestedUids, ['user-a', 'user-b']);
      expect(sockets, hasLength(1));
      expect(
        sockets.single.joinFrames.every(
          (frame) => frame['payload']['access_token'] == 'jwt-user-b',
        ),
        isTrue,
      );
      service.dispose();
    });

    test(
      'websocketUri uses wss, the realtime path and the publishable key',
      () {
        final service = ChatRealtimeService(
          baseUrl: 'https://example.supabase.co',
          anonKey: 'public-anon-key',
          tokenProvider: (userId) async => 'jwt',
        );
        final uri = service.websocketUri;
        expect(uri.scheme, 'wss');
        expect(uri.host, 'example.supabase.co');
        expect(uri.path, '/realtime/v1/websocket');
        expect(uri.queryParameters['apikey'], 'public-anon-key');
        expect(uri.queryParameters['vsn'], '1.0.0');
        // No service-role or JWT is embedded in the URL.
        expect(uri.toString(), isNot(contains('jwt')));
        expect(uri.toString(), isNot(contains('service_role')));
        service.dispose();
      },
    );
  });
}

class _FakeRealtimeSocket implements WebSocketChannel {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast(sync: true);
  final List<String> sentFrames = <String>[];
  late final WebSocketSink _sink = _FakeRealtimeSink(_incoming, sentFrames);

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  List<Map<String, dynamic>> get joinFrames => sentFrames
      .map(jsonDecode)
      .whereType<Map>()
      .map((frame) => Map<String, dynamic>.from(frame))
      .where((frame) => frame['event'] == 'phx_join')
      .toList(growable: false);

  void addFrame(Object frame) {
    if (!_incoming.isClosed) _incoming.add(frame);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRealtimeSink implements WebSocketSink {
  _FakeRealtimeSink(this._incoming, this.sentFrames);

  final StreamController<dynamic> _incoming;
  final List<String> sentFrames;

  @override
  void add(dynamic data) => sentFrames.add(data.toString());

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    // A real WebSocketSink closes asynchronously; defer this fake's broadcast
    // controller close until the synchronous frame callback has unwound.
    await Future<void>.delayed(Duration.zero);
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
