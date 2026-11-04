import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/services/api_client.dart';

void main() {
  const supabaseUrl = 'https://project.example.supabase.co';
  const anonKey = 'public-anon-key';
  const accessToken = 'supabase-user-jwt';
  const authUid = '00000000-0000-4000-8000-000000000099';
  const profileId = 'client_legal_001';

  ApiClient makeClient(Future<http.Response> Function(http.Request) handler) =>
      ApiClient(
        supabaseUrl: supabaseUrl,
        supabaseAnonKey: anonKey,
        client: MockClient(handler),
        idTokenProvider: () async => accessToken,
        currentUidProvider: () => authUid,
      );

  http.Response profileResponse() => http.Response(
        jsonEncode([
          {
            'id': profileId,
            'uid': profileId,
            'name': 'Client One',
            'email': 'client@example.test',
            'role': 'client',
          },
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );

  test('uploads validated PDF bytes through the trusted Edge Function', () async {
    const pdfBytes = <int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x37];
    const objectPath = '$profileId/documents/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pdf';
    final requests = <http.Request>[];
    final client = makeClient((request) async {
      requests.add(request);
      if (request.url.path == '/rest/v1/users') return profileResponse();
      return http.Response(
        jsonEncode({'object_path': objectPath}),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.dispose);

    final path = await client.uploadPrivatePdf(pdfBytes);
    final upload = requests.last;

    expect(path, objectPath);
    expect(requests, hasLength(2));
    expect(requests.first.url.path, '/rest/v1/users');
    expect(upload.method, 'POST');
    expect(upload.url.origin, supabaseUrl);
    expect(upload.url.path, '/functions/v1/document-upload');
    expect(upload.headers['apikey'], anonKey);
    expect(upload.headers['Authorization'], 'Bearer $accessToken');
    expect(upload.headers['Content-Type'], 'application/pdf');
    expect(upload.headers.containsKey('x-upsert'), isFalse);
    expect(upload.bodyBytes, pdfBytes);
  });

  test('invokes an Edge Function with a JWT and JSON, not a provider secret', () async {
    late http.Request captured;
    final client = makeClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({'answer': 'General information only.', 'advisory': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.dispose);

    final response = await client.invokeSupabaseFunction('ai-assistant', {
      'action': 'legal_chat',
      'question': 'What does a lease usually contain?',
    });

    expect(captured.method, 'POST');
    expect(captured.url.path, '/functions/v1/ai-assistant');
    expect(captured.headers['apikey'], anonKey);
    expect(captured.headers['Authorization'], 'Bearer $accessToken');
    expect(captured.headers.containsKey('x-goog-api-key'), isFalse);
    expect(jsonDecode(captured.body), {
      'action': 'legal_chat',
      'question': 'What does a lease usually contain?',
    });
    expect(response['answer'], 'General information only.');
    expect(response['advisory'], isTrue);
  });

  test('refuses cross-owner temporary PDF cleanup before Storage deletion', () async {
    final requests = <http.Request>[];
    final client = makeClient((request) async {
      requests.add(request);
      if (request.url.path == '/rest/v1/users') return profileResponse();
      return http.Response('{}', 200);
    });
    addTearDown(client.dispose);

    await expectLater(
      client.deletePrivatePdf('another_user/documents/report_1.pdf'),
      throwsA(isA<ApiException>().having((error) => error.statusCode, 'statusCode', 403)),
    );
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/rest/v1/users');
  });

  test('rejects an invalid PDF signature before contacting Supabase', () async {
    var requests = 0;
    final client = makeClient((_) async {
      requests++;
      return profileResponse();
    });
    addTearDown(client.dispose);

    await expectLater(
      client.uploadPrivatePdf(const <int>[0, 1, 2, 3, 4]),
      throwsA(isA<ApiException>().having((error) => error.statusCode, 'statusCode', 415)),
    );
    expect(requests, 0);
  });

  test('surfaces a failed trusted upload rather than reporting success', () async {
    final requests = <http.Request>[];
    final client = makeClient((request) async {
      requests.add(request);
      if (request.url.path == '/rest/v1/users') return profileResponse();
      return http.Response(
        jsonEncode({'error': 'DOCUMENT_UPLOAD_FAILED'}),
        502,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.dispose);

    await expectLater(
      client.uploadPrivatePdf(const <int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31]),
      throwsA(isA<ApiException>().having((error) => error.statusCode, 'statusCode', 502)),
    );
    expect(requests, hasLength(2));
    expect(requests.last.url.path, '/functions/v1/document-upload');
  });
}
