// LOCAL REVIEW ONLY. Production lib/main.dart never imports this entrypoint.
// Uses the ORIGINAL HomePage, SessionScope, repositories and Samaha components.
// Real bundled directory assets. Only operational home reads are mocked.
// No live Supabase connection or Auth account; never used by production bootstrap.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legalserviceapp/constants/colors.dart';
import 'package:legalserviceapp/services/api_client.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/state/session_scope.dart';
import 'package:legalserviceapp/views/home/homescreen.dart';

Future<void> main() async {
  if (!const bool.fromEnvironment('SAMAHA_LOCAL_PREVIEW')) {
    throw StateError(
      'Local review requires --dart-define=SAMAHA_LOCAL_PREVIEW=true. Use lib/main.dart for the real application.',
    );
  }
  WidgetsFlutterBinding.ensureInitialized();
  const homeFixtures = bool.fromEnvironment('HOME_LAYOUT_FIXTURES');
  final previewScale =
      (double.tryParse(Uri.base.queryParameters['textScale'] ?? '1') ?? 1)
          .clamp(1.0, 2.0)
          .toDouble();
  final fixtureImage = homeFixtures ? await _drawGenericPreviewAvatar() : null;
  // Enable accessible browser navigation for the lifetime of this local review.
  SemanticsBinding.instance.ensureSemantics();
  final api = ApiClient(
    supabaseUrl: 'https://local-preview.invalid',
    supabaseAnonKey: 'local-fixture-not-a-real-key',
    client: MockClient((request) async {
      if (request.method != 'GET') {
        return http.Response('{"message":"Read-only local review"}', 403);
      }
      final table = request.url.pathSegments.last;
      // Only operational home sections are mocked. Samaha uses the exact
      // production AssetBundle repository, with no fixture table transport.
      if (table != 'lawyers' && table != 'legal_categories') {
        return http.Response(
          '{"message":"Operational accounts are unavailable in local review"}',
          403,
        );
      }
      // Explicitly synthetic, opt-in layout records. They exist only in this
      // MockClient; there are no inserts, accounts, Samaha identities or portraits.
      List<Map<String, Object>> rows =
          !homeFixtures
              ? []
              : table == 'legal_categories'
              ? [
                {
                  'id': 'layout-family',
                  'name': 'Family law',
                  'slug': 'family-law',
                },
                {
                  'id': 'layout-business',
                  'name': 'Business law',
                  'slug': 'business-law',
                },
              ]
              : List.generate(22, (index) {
                final n = (index + 1).toString().padLeft(2, '0');
                return {
                  'id': 'layout-demo-$n',
                  'name': 'Layout demo $n · نموذج تجريبي',
                  'category_id':
                      index.isEven ? 'layout-family' : 'layout-business',
                  'specialty':
                      index.isEven
                          ? 'Family law · بيانات تجريبية'
                          : 'Business law · بيانات تجريبية',
                  'price': 'EGP 50',
                  'price_value': 50.0,
                  'rating': 4.5,
                  'image': _fixtureAsset,
                  'bio':
                      'Synthetic layout fixture. Not a real lawyer, identity, account or Samaha profile.',
                };
              });
      for (final field in ['id', 'category_id']) {
        final filter = request.url.queryParameters[field];
        if (filter != null && filter.startsWith('eq.')) {
          rows =
              rows.where((row) => row[field] == filter.substring(3)).toList();
        }
      }
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '100') ?? 100;
      final page = rows.skip(offset).take(limit).toList();
      return http.Response(
        jsonEncode(page),
        200,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'content-range':
              page.isEmpty
                  ? '*/${rows.length}'
                  : '$offset-${offset + page.length - 1}/${rows.length}',
        },
      );
    }),
  );
  final session = SessionController(
    auth: AuthService(gateway: _LocalReadOnlyAuth(), api: api),
  );
  runApp(
    DefaultAssetBundle(
      bundle: _PreviewBundle(fixtureImage),
      child: SessionScope(
        controller: session,
        child: MaterialApp(
          title: 'Legal · Samaha local review',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            scaffoldBackgroundColor: AppColors.bgColor,
            colorScheme: ColorScheme.fromSeed(seedColor: AppColors.buttonColor),
          ),
          builder:
              (context, child) => Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: AppColors.buttonColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: const Text(
                      homeFixtures
                          ? 'LOCAL UI TEST · Synthetic lawyer cards, not real people · بطاقات اختبار فقط، ليست بيانات أشخاص'
                          : 'LOCAL REVIEW · Real bundled directory assets · Operational home data mocked',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: Colors.white,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  Expanded(
                    child: MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(previewScale)),
                      child: child!,
                    ),
                  ),
                ],
              ),
          home: const HomePage(),
        ),
      ),
    ),
  );
}

class _LocalReadOnlyAuth implements AuthGateway {
  @override
  AuthUser? get currentUser => null;
  @override
  Stream<AuthUser?> get authStateChanges => const Stream.empty();
  @override
  Stream<AuthUser?> get sessionChanges => const Stream.empty();
  @override
  Future<AuthUser?> restoreSession({Uri? callbackUri}) async => null;
  @override
  Future<void> signOut() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(
        'Account actions are unavailable in the local review. Production authentication is unchanged.',
      );
}

// An in-memory geometric avatar, NOT a portrait or an invented identity.
// No production asset, data file, image mapping or asset manifest is changed.
const _fixtureAsset = 'local-preview-only/generic-layout-avatar.png';

Future<ByteData> _drawGenericPreviewAvatar() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 640, 480),
    Paint()..color = const Color(0xFFE9EFF8),
  );
  canvas.drawCircle(const Offset(320, 240), 178, Paint()..color = Colors.white);
  final ink = Paint()..color = const Color(0xFF5079A7);
  canvas.drawCircle(const Offset(320, 170), 54, ink);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(222, 250, 196, 136),
      const Radius.circular(80),
    ),
    ink,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(640, 480);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (bytes == null) throw StateError('Could not create local layout fixture');
  return bytes;
}

class _PreviewBundle extends CachingAssetBundle {
  _PreviewBundle(this.fixture);
  final ByteData? fixture;
  @override
  Future<ByteData> load(String key) async {
    if (key == _fixtureAsset && fixture != null) return fixture!;
    return rootBundle.load(key);
  }
}
