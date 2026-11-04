// Repository-level chat tests: verify the exact RPC names/arguments used to
// start a conversation and send idempotent messages, and that no privileged
// key ever appears in a request.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/app_repository.dart';

import 'support/fakes.dart';

void main() {
  group('AppRepository chat RPCs', () {
    test(
      'startChatWithLawyer calls the server resolver with real IDs and null client id',
      () async {
        http.Request? captured;
        final api = testApiClient(
          handler: (request, attempt) async {
            captured = request;
            return supabaseOk({
              'chat': {
                'id': 'chat-1',
                'participants': ['client-1', 'lawyer-user-1'],
                'last_message': 'Hello',
              },
              'reused': false,
            });
          },
        );
        final repo = AppRepository(api);

        final chat = await repo.startChatWithLawyer(
          lawyerId: 'lawyer-1',
          initialMessage: 'Hello',
          bookingId: 'booking-1',
        );

        expect(chat['id'], 'chat-1');
        expect(captured!.method, 'POST');
        expect(captured!.url.path, '/rest/v1/rpc/rpc_chat_start_with_lawyer');
        final body = jsonDecode(captured!.body) as Map<String, dynamic>;
        expect(body['p_lawyer_id'], 'lawyer-1');
        expect(body['p_initial_message'], 'Hello');
        expect(body['p_booking_id'], 'booking-1');
        // The caller must never claim a client id; the server resolves it.
        expect(body.containsKey('p_client_id'), isTrue);
        expect(body['p_client_id'], isNull);
      },
    );

    test(
      'sendMessage carries a client idempotency id so retries never duplicate',
      () async {
        http.Request? captured;
        final api = testApiClient(
          handler: (request, attempt) async {
            captured = request;
            return supabaseOk({
              'id': 'integmsg0001',
              'chat_id': 'chat-1',
              'sender_id': 'client-1',
              'text': 'Hello',
              'replayed': false,
            });
          },
        );
        final repo = AppRepository(api);

        final row = await repo.sendMessage(
          chatId: 'chat-1',
          text: '  Hello  ',
          clientMessageId: 'integmsg0001',
        );

        expect(row['id'], 'integmsg0001');
        expect(captured!.url.path, '/rest/v1/rpc/rpc_chat_send_message');
        final body = jsonDecode(captured!.body) as Map<String, dynamic>;
        expect(body['p_chat_id'], 'chat-1');
        expect(body['p_text'], 'Hello');
        expect(body['p_client_message_id'], 'integmsg0001');
      },
    );

    test(
      'maps PostgREST MESSAGE_ID_CONFLICT to actionable chat copy',
      () async {
        final api = testApiClient(
          handler:
              (request, attempt) async => http.Response(
                jsonEncode({'code': '23505', 'message': 'MESSAGE_ID_CONFLICT'}),
                409,
                headers: {'content-type': 'application/json'},
              ),
        );
        final repo = AppRepository(api);

        await expectLater(
          repo.sendMessage(
            chatId: 'chat-1',
            text: 'Hello',
            clientMessageId: 'integmsg0002',
          ),
          throwsA(
            isA<ApiException>()
                .having((error) => error.statusCode, 'statusCode', 409)
                .having(
                  (error) => error.message,
                  'message',
                  contains('Refresh the conversation'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('MESSAGE_ID_CONFLICT')),
                ),
          ),
        );
      },
    );

    test(
      'fetchChats follows authenticated pages beyond the first 100 rows',
      () async {
        final requests = <http.Request>[];
        final allChats = List<Map<String, dynamic>>.generate(
          150,
          (index) => <String, dynamic>{
            'id': 'chat-${index.toString().padLeft(3, '0')}',
            'participants': ['client-1', 'lawyer-user-1'],
            'participant_names': <String, String>{},
            'last_message': 'Message $index',
            'created_at': '2026-10-28T10:00:00Z',
            'updated_at':
                DateTime.utc(
                  2026,
                  10,
                  28,
                  10,
                ).add(Duration(minutes: index)).toIso8601String(),
          },
        );
        final api = testApiClient(
          handler: (request, attempt) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/chats')) {
              requests.add(request);
              final cursorFilter = request.url.queryParameters['id'];
              final cursor =
                  cursorFilter == null ? null : cursorFilter.substring(3);
              final candidates =
                  cursor == null
                      ? allChats
                      : allChats
                          .where(
                            (chat) =>
                                chat['id'].toString().compareTo(cursor) > 0,
                          )
                          .toList(growable: false);
              final limit = int.parse(request.url.queryParameters['limit']!);
              final items = candidates.take(limit).toList();
              final end = items.length - 1;
              return supabaseOk(
                items,
                headers: {'content-range': '0-$end/${candidates.length}'},
              );
            }
            return supabaseOk([]);
          },
        );

        final chats = await AppRepository(api).fetchChats();

        expect(chats, hasLength(150));
        expect(chats.first['id'], 'chat-149');
        expect(chats.last['id'], 'chat-000');
        expect(requests, hasLength(2));
        expect(requests.first.url.queryParameters['id'], isNull);
        expect(requests.last.url.queryParameters['id'], 'gt.chat-099');
        expect(requests.map((r) => r.url.queryParameters['offset']), [
          '0',
          '0',
        ]);
        expect(requests.map((r) => r.url.queryParameters['limit']), [
          '100',
          '100',
        ]);
        expect(requests.map((r) => r.url.queryParameters['order']), [
          'id.asc',
          'id.asc',
        ]);
        expect(requests.first.headers['Prefer'], 'count=exact');
      },
    );

    test(
      'fetchChats rejects a changed exact count between keyset pages',
      () async {
        var page = 0;
        final api = testApiClient(
          handler: (request, attempt) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/chats')) {
              page++;
              if (page == 1) {
                return supabaseOk(
                  List<Map<String, dynamic>>.generate(
                    100,
                    (index) => <String, dynamic>{
                      'id': 'chat-${index.toString().padLeft(3, '0')}',
                      'updated_at': '2026-10-28T10:00:00Z',
                    },
                  ),
                  headers: {'content-range': '0-99/150'},
                );
              }
              return supabaseOk(
                List<Map<String, dynamic>>.generate(
                  49,
                  (index) => <String, dynamic>{
                    'id': 'chat-${(index + 100).toString().padLeft(3, '0')}',
                    'updated_at': '2026-10-28T10:00:00Z',
                  },
                ),
                headers: {'content-range': '0-48/49'},
              );
            }
            return supabaseOk([]);
          },
        );

        await expectLater(
          AppRepository(api).fetchChats(),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'message',
              contains('changed during pagination'),
            ),
          ),
        );
        expect(page, 2);
      },
    );

    test(
      'fetchChats refuses unbounded results without an exact count',
      () async {
        final api = testApiClient(
          handler: (request, attempt) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/chats')) {
              return supabaseOk([
                {'id': 'chat-1', 'updated_at': '2026-10-28T10:00:00Z'},
              ]);
            }
            return supabaseOk([]);
          },
        );

        await expectLater(
          AppRepository(api).fetchChats(),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'message',
              contains('exact count'),
            ),
          ),
        );
      },
    );

    test('fetchChats rejects overlapping keyset pages', () async {
      var page = 0;
      final api = testApiClient(
        handler: (request, attempt) async {
          if (request.method == 'GET' && request.url.path.endsWith('/chats')) {
            page++;
            if (page == 1) {
              return supabaseOk(
                List<Map<String, dynamic>>.generate(
                  100,
                  (index) => <String, dynamic>{
                    'id': 'chat-${index.toString().padLeft(3, '0')}',
                    'updated_at': '2026-10-28T10:00:00Z',
                  },
                ),
                headers: {'content-range': '0-99/101'},
              );
            }
            return supabaseOk(
              [
                {'id': 'chat-099', 'updated_at': '2026-10-28T10:00:00Z'},
              ],
              headers: {'content-range': '0-0/1'},
            );
          }
          return supabaseOk([]);
        },
      );

      await expectLater(
        AppRepository(api).fetchChats(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('overlapping page'),
          ),
        ),
      );
      expect(page, 2);
    });

    test(
      'fetchChatMessages refuses an inaccessible chat before reading its messages',
      () async {
        var messageCalls = 0;
        final api = testApiClient(
          handler: (request, attempt) async {
            if (request.url.path.endsWith('/chats')) return supabaseOk([]);
            if (request.url.path.endsWith('/rpc/rpc_chat_messages_page')) {
              messageCalls++;
              return supabaseOk({});
            }
            return supabaseOk([]);
          },
        );

        await expectLater(
          AppRepository(api).fetchChatMessages('chat-private'),
          throwsA(
            isA<ApiException>().having(
              (error) => error.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
        expect(messageCalls, 0);
      },
    );

    test(
      'fetchChatMessages rejects a message belonging to another chat',
      () async {
        final api = testApiClient(
          handler: (request, attempt) async {
            if (request.url.path.endsWith('/chats')) {
              return supabaseOk([
                {
                  'id': 'chat-1',
                  'participants': ['client-1', 'lawyer-user-1'],
                  'participant_names': <String, String>{},
                  'last_message': 'Hello',
                },
              ]);
            }
            if (request.url.path.endsWith('/rpc/rpc_chat_messages_page')) {
              return supabaseOk({
                'items': [
                  {
                    'id': 'message-1',
                    'chat_id': 'chat-2',
                    'sender_id': 'client-1',
                    'text': 'Not this chat',
                    'created_at': '2026-10-28T10:00:00Z',
                  },
                ],
                'has_more': false,
                'next_before_created_at': null,
                'next_before_id': null,
              });
            }
            return supabaseOk([]);
          },
        );

        await expectLater(
          AppRepository(api).fetchChatMessages('chat-1'),
          throwsA(
            isA<ApiException>().having(
              (error) => error.message,
              'message',
              contains('cross-chat'),
            ),
          ),
        );
      },
    );

    test(
      'fetchChatMessages reads all authorized message pages in chronological order',
      () async {
        final messageRequests = <http.Request>[];
        final api = testApiClient(
          handler: (request, attempt) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/chats')) {
              return supabaseOk([
                {
                  'id': 'chat-1',
                  'participants': ['client-1', 'lawyer-user-1'],
                  'participant_names': {
                    'client-1': 'Client',
                    'lawyer-user-1': 'Lawyer',
                  },
                  'last_message': 'Newest',
                },
              ]);
            }
            if (request.url.path.endsWith('/rpc/rpc_chat_messages_page')) {
              messageRequests.add(request);
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              if (body['p_before_id'] == null) {
                return supabaseOk({
                  'items': [
                    {
                      'id': 'm-2',
                      'chat_id': 'chat-1',
                      'sender_id': 'lawyer-user-1',
                      'sender_name': 'Lawyer',
                      'text': 'Newer',
                      'created_at': '2026-10-28T10:00:00Z',
                    },
                  ],
                  'has_more': true,
                  'next_before_created_at': '2026-10-28T10:00:00Z',
                  'next_before_id': 'm-2',
                });
              }
              return supabaseOk({
                'items': [
                  {
                    'id': 'm-1',
                    'chat_id': 'chat-1',
                    'sender_id': 'client-1',
                    'sender_name': 'Client',
                    'text': 'Earlier',
                    'created_at': '2026-10-28T09:00:00Z',
                  },
                ],
                'has_more': false,
                'next_before_created_at': '2026-10-28T09:00:00Z',
                'next_before_id': 'm-1',
              });
            }
            return supabaseOk([]);
          },
        );
        final data = await AppRepository(api).fetchChatMessages('chat-1');
        final messages = data['messages'] as List<Map<String, dynamic>>;
        expect(messages.map((row) => row['id']).toList(), ['m-1', 'm-2']);
        expect(messageRequests, hasLength(2));
        expect(jsonDecode(messageRequests.first.body)['p_before_id'], isNull);
        expect(jsonDecode(messageRequests.last.body)['p_before_id'], 'm-2');
      },
    );

    test(
      'newClientMessageId is unique and long enough for the server pattern',
      () {
        final repo = AppRepository(
          testApiClient(handler: (request, attempt) async => supabaseOk({})),
        );
        final ids = List.generate(20, (_) => repo.newClientMessageId()).toSet();
        expect(ids, hasLength(20));
        for (final id in ids) {
          expect(RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(id), isTrue);
        }
      },
    );

    test('no request contains a service-role or sb_secret key', () async {
      final seen = <String>[];
      final api = testApiClient(
        handler: (request, attempt) async {
          seen
            ..add(request.body)
            ..add(request.headers.toString())
            ..add(request.url.toString());
          return supabaseOk({
            'chat': {'id': 'chat-1'},
            'reused': false,
          });
        },
      );
      final repo = AppRepository(api);
      await repo.startChatWithLawyer(lawyerId: 'lawyer-1');
      expect(seen.join('\n').contains('service_role'), isFalse);
      expect(seen.join('\n').contains('sb_secret_'), isFalse);
    });

    test(
      'an {error: CODE} RPC result is mapped to a friendly ApiException',
      () async {
        final api = testApiClient(
          handler: (request, attempt) async {
            // Some chat/booking RPCs return a 200 with a domain error object.
            return supabaseOk({'error': 'LAWYER_ACCOUNT_NOT_LINKED'});
          },
        );
        final repo = AppRepository(api);
        await expectLater(
          repo.startChatWithLawyer(lawyerId: 'lawyer-1'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              contains('no verified account'),
            ),
          ),
        );
      },
    );
  });
}
