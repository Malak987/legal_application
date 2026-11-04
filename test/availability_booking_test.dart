// Availability + booking screen.
//
// WHAT THESE TESTS PIN
// --------------------
// The screen used to render a hardcoded September-2024 schedule and a Confirm
// button wired to `() {}`. These tests hold the replacement in place:
//
//  * slot strings in either notation (`09:00`, `9:00 am`) parse to the same time;
//  * the calendar bounds are computed from today, so they cannot expire;
//  * authenticated slots come from the bounded Cairo-time refresh RPC (anonymous
//    browsing remains a public availability read);
//  * a duration is offered only while every hour it spans is published and free;
//  * Confirm sends `POST /api/bookings` with the date the UI is showing and the
//    lawyer id the screen was given, exactly once even when tapped twice;
//  * a 409 from the server is surfaced and the schedule is reloaded;
//  * the drawer's entry point (no lawyer id) lists real lawyers instead of
//    inventing one.
//
// The HTTP layer is a MockClient (`testApiClient`), so no socket is opened and
// no Firebase credential is involved. `testWidgets` fakes timers, so every wait
// on a real HTTP future happens inside `tester.runAsync`.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:legalserviceapp/models/lawyer_availability.dart';
import 'package:legalserviceapp/services/auth_service.dart';
import 'package:legalserviceapp/state/session_controller.dart';
import 'package:legalserviceapp/state/session_scope.dart';
import 'package:legalserviceapp/views/availablitycalendar/avaialblity_calendar.dart';
import 'package:table_calendar/table_calendar.dart';

import 'support/fakes.dart';

// ---------------------------------------------------------------------------
// Time helpers: pure functions, no widgets.
// ---------------------------------------------------------------------------

void _availabilityModelTests() {
  test('parses 24-hour and 12-hour slot notation to the same minute', () {
    expect(LawyerAvailability.parseClockTime('09:00'), 540);
    expect(LawyerAvailability.parseClockTime('9:00 am'), 540);
    expect(LawyerAvailability.parseClockTime('09:00 AM'), 540);
    expect(LawyerAvailability.parseClockTime('12:00 am'), 0);
    expect(LawyerAvailability.parseClockTime('12:00 pm'), 720);
    expect(LawyerAvailability.parseClockTime('01:30 PM'), 810);
    expect(LawyerAvailability.parseClockTime('23:45'), 1425);
  });

  test('rejects values that are not a time of day', () {
    expect(LawyerAvailability.parseClockTime(''), isNull);
    expect(LawyerAvailability.parseClockTime('9'), isNull);
    expect(LawyerAvailability.parseClockTime('24:00'), isNull);
    expect(LawyerAvailability.parseClockTime('09:60'), isNull);
    expect(LawyerAvailability.parseClockTime('13:00 pm'), isNull);
  });

  test('formats times for the API and for the UI', () {
    expect(LawyerAvailability.apiTime(540), '09:00');
    expect(LawyerAvailability.apiTime(0), '00:00');
    expect(LawyerAvailability.apiTime(1425), '23:45');
    expect(LawyerAvailability.label(540), '9:00 AM');
    expect(LawyerAvailability.label(0), '12:00 AM');
    expect(LawyerAvailability.label(720), '12:00 PM');
    expect(LawyerAvailability.label(810), '1:30 PM');
  });

  test('date keys round-trip without a timezone shift', () {
    final day = DateTime(2026, 11, 1);
    expect(LawyerAvailability.dateKey(day), '2026-11-01');
    expect(LawyerAvailability.parseDateKey('2026-11-01'), day);
    expect(LawyerAvailability.parseDateKey('2026-02-30'), isNull);
    expect(LawyerAvailability.parseDateKey('01/11/2026'), isNull);
  });

  test('sorts, de-duplicates and drops unusable slots', () {
    final row = LawyerAvailability.fromJson({
      'id': 'av-1',
      'lawyerId': 'lawyer-1',
      'date': '2026-11-01',
      'slots': ['10:00', '9:00 am', '10:00', '', 'noon'],
    });
    expect(row.slots, [540, 600]);
    expect(row.isEmpty, isFalse);
  });
}

// ---------------------------------------------------------------------------
// Widget harness.
// ---------------------------------------------------------------------------

/// Routes the handful of endpoints this screen touches.
class _Fake {
  _Fake({
    this.availability = const <Map<String, dynamic>>[],
    this.bookings = const <Map<String, dynamic>>[],
    this.lawyers = const <Map<String, dynamic>>[],
    this.availabilityStatus = 200,
    this.bookingStatus = 201,
    this.bookingMessage = 'That time is no longer available.',
    this.bookingRpcError,
  });

  final List<Map<String, dynamic>> availability;
  final List<Map<String, dynamic>> bookings;
  final List<Map<String, dynamic>> lawyers;
  final int availabilityStatus;
  final int bookingStatus;
  final String bookingMessage;
  final String? bookingRpcError;

  int availabilityCalls = 0;
  int bookingCalls = 0;
  final List<http.Request> availabilityRequests = <http.Request>[];
  final List<Map<String, dynamic>> bookingBodies = <Map<String, dynamic>>[];

  Future<http.Response> handle(http.Request request, int attempt) async {
    final path = request.url.path;
    final method = request.method;

    if (path.contains('/users')) {
      return supabaseOk([profileJson()]);
    }
    if (path.endsWith('/rpc/rpc_refresh_lawyer_availability') &&
        method == 'POST') {
      availabilityCalls++;
      availabilityRequests.add(request);
      if (availabilityStatus != 200) {
        return supabaseError(
          availabilityStatus,
          'Availability is unavailable.',
        );
      }
      return supabaseOk({
        'items': availability,
        'timezone': 'Africa/Cairo',
        'horizon_days': 90,
      });
    }
    if (path.contains('/availability') && method == 'GET') {
      availabilityCalls++;
      if (availabilityStatus != 200) {
        return jsonError(availabilityStatus, 'Availability is unavailable.');
      }
      return supabaseOk(
        availability,
        headers: {
          'content-range':
              '0-${availability.length - 1}/${availability.length}',
        },
      );
    }
    if ((path.contains('/lawyers/') ||
            request.url.queryParameters.containsKey('id')) &&
        method == 'GET') {
      final id =
          path.split('/').last.isNotEmpty && path.split('/').last != 'lawyers'
              ? path.split('/').last
              : (request.url.queryParameters['id']?.replaceAll('eq.', '') ??
                  'lawyer-1');
      return supabaseOk([
        {
          'id': id,
          'name': 'Mona Fahmy',
          'specialty': 'Family law',
          'price': '250 EGP',
          'price_value': 250,
        },
      ]);
    }
    if (path.contains('/lawyers') && method == 'GET') {
      return supabaseOk(
        lawyers,
        headers: {'content-range': '0-${lawyers.length - 1}/${lawyers.length}'},
      );
    }
    if (path.contains('/bookings') && method == 'GET') {
      return supabaseOk(
        bookings,
        headers: {
          'content-range': '0-${bookings.length - 1}/${bookings.length}',
        },
      );
    }
    if (path.contains('/rpc/rpc_create_booking') && method == 'POST') {
      bookingCalls++;
      final rawBody = jsonDecode(request.body) as Map<String, dynamic>;
      bookingBodies.add({
        'lawyerId': rawBody['p_lawyer_id'],
        'date': rawBody['p_date'],
        'time': rawBody['p_time'],
        'hours': rawBody['p_hours'],
      });
      if (bookingRpcError != null) {
        return supabaseOk({'error': bookingRpcError});
      }
      if (bookingStatus != 201) {
        return supabaseError(bookingStatus, bookingMessage);
      }
      return supabaseOk({
        'booking': {
          'id': 'bk-new',
          'user_id': 'uid-1',
          'lawyer_id': rawBody['p_lawyer_id'],
          'total_price': 250,
          'status': 'Pending',
        },
      });
    }
    if (path.contains('/bookings') && method == 'POST') {
      bookingCalls++;
      bookingBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (bookingStatus != 201) {
        return jsonError(bookingStatus, bookingMessage);
      }
      return supabaseOk({
        'id': 'bk-new',
        'user_id': 'uid-1',
        'total_price': 250,
        'status': 'Pending',
      });
    }
    return supabaseOk(<Map<String, dynamic>>[]);
  }
}

/// Availability rows for [days] consecutive days starting today, all offering
/// [slots]. Relative to "today" so the tests never depend on the run date.
List<Map<String, dynamic>> _availabilityFromToday(
  int days,
  List<String> slots, {
  String lawyerId = 'lawyer-1',
}) {
  final today = DateTime.now();
  return [
    for (var i = 0; i < days; i++)
      {
        'id': 'av-$i',
        'lawyerId': lawyerId,
        'date': LawyerAvailability.dateKey(
          DateTime(today.year, today.month, today.day + i),
        ),
        'slots': slots,
      },
  ];
}

// ---------------------------------------------------------------------------
// Screen tests.
// ---------------------------------------------------------------------------

void _screenTests() {
  /// Runs real async for a bounded time, then renders frames.
  ///
  /// The profile load, the availability read, the bookings read and the booking
  /// POST form a chain of real futures; pumping a fixed number of frames would
  /// be guessing how far along that chain the screen is. A short real-time drain
  /// is deterministic, because MockClient answers immediately.
  Future<void> drain(WidgetTester tester, {int frames = 2}) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    for (var i = 0; i < frames; i++) {
      await tester.pump();
    }
  }

  /// Builds the screen inside a signed-in session, as the drawer would.
  Future<SessionController> pumpScreen(
    WidgetTester tester,
    _Fake fake, {
    String? lawyerId,
    String? lawyerName,
  }) async {
    final gateway = FakeAuthGateway();
    final session = SessionController(
      auth: AuthService(
        gateway: gateway,
        api: testApiClient(handler: fake.handle, userProfile: profileJson()),
      ),
    );
    addTearDown(session.dispose);

    // Sign in before the screen exists, so its first load already sees a
    // signed-in session (the screen reads `isSignedIn` to decide whether to
    // fetch the caller's own bookings).
    session.start();
    gateway.emit(const AuthUser(uid: 'uid-1', email: 'sara@example.com'));
    await drain(tester);
    expect(session.isSignedIn, isTrue, reason: 'the fake grants a profile');

    await tester.pumpWidget(
      SessionScope(
        controller: session,
        child: MaterialApp(
          home: AvailabilityCalendarScheduleScreen(
            lawyerId: lawyerId,
            lawyerName: lawyerName,
          ),
        ),
      ),
    );

    // The screen starts its requests in a post-frame callback.
    await drain(tester);
    return session;
  }

  /// Scrolls [finder] into view (the schedule is one scroll view) and taps it.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  /// The calendar cells showing [day], in tree order.
  Finder dayCells(int day) => find.descendant(
    // `find.byType` compares `runtimeType` exactly, so the generic
    // argument has to be spelled out or nothing matches.
    of: find.byType(TableCalendar<int>),
    matching: find.text('$day'),
  );

  /// The date shown in the slot header, or `null` while none is selected.
  String? selectedDate(WidgetTester tester) {
    final header = find.textContaining('Available slots for');
    if (header.evaluate().isEmpty) return null;
    final label = tester.widget<Text>(header.first).data ?? '';
    return label.replaceFirst('Available slots for ', '');
  }

  /// Taps a calendar day and returns the date the screen selected, or `null`.
  ///
  /// The calendar is a `PageView`, so a day number also appears on the
  /// neighbouring month's page. Those cells sit outside the calendar's own
  /// rectangle; tapping them would be a miss, and asking the framework to scroll
  /// a cell into view would paginate the calendar instead (`Scrollable
  /// .ensureVisible` drives *every* ancestor scrollable, including the
  /// horizontal page view). This taps raw coordinates, so only on-screen cells
  /// receive the pointer.
  Future<String?> tapDay(WidgetTester tester, int day) async {
    final calendar = find.byType(TableCalendar<int>);
    if (calendar.evaluate().isEmpty) return null;
    final rect = tester.getRect(calendar);

    for (var index = 0; index < dayCells(day).evaluate().length; index++) {
      final cells = dayCells(day);
      if (cells.evaluate().length <= index) break;

      final center = tester.getCenter(cells.at(index));
      if (!rect.contains(center)) continue;

      await tester.tapAt(center);
      await tester.pump();

      final date = selectedDate(tester);
      if (date != null) return date;
    }
    return null;
  }

  /// Selects any date that has published availability.
  ///
  /// Which day is selectable depends on the availability each test seeds, and
  /// days without availability are deliberately not selectable, so this walks
  /// the day numbers until one of them changes the selection.
  Future<String> selectAnyDate(WidgetTester tester) async {
    for (var day = 1; day <= 31; day++) {
      final date = await tapDay(tester, day);
      if (date != null) return date;
    }
    final calendar = find.byType(TableCalendar<int>);
    final widget =
        calendar.evaluate().isEmpty
            ? null
            : tester.widget<TableCalendar<int>>(calendar.first);
    fail(
      'no date on the calendar could be selected: '
      'focused=${widget?.focusedDay} first=${widget?.firstDay} '
      'last=${widget?.lastDay}',
    );
  }

  testWidgets('shows the published slots of the lawyer it was given', (
    tester,
  ) async {
    final fake = _Fake(
      availability: _availabilityFromToday(1, ['9:00 am', '10:30']),
    );
    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');

    // The name comes from the lawyer record, not from a constant.
    expect(find.text('Mona Fahmy'), findsOneWidget);
    expect(fake.availabilityCalls, 1);
    expect(
      fake.availabilityRequests.single.url.path,
      '/rest/v1/rpc/rpc_refresh_lawyer_availability',
    );
    expect(jsonDecode(fake.availabilityRequests.single.body), {
      'p_lawyer_id': 'lawyer-1',
    });

    await selectAnyDate(tester);

    // The seed's `9:00 am` and the API's `10:30` both reach the UI.
    expect(find.text('9:00 AM'), findsOneWidget);
    expect(find.text('10:30 AM'), findsOneWidget);
    // The old hardcoded sample slots are gone.
    expect(find.text('11:00 AM'), findsNothing);
  });

  testWidgets('the calendar starts today and cannot expire', (tester) async {
    final fake = _Fake();
    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');

    final calendar = tester.widget<TableCalendar<int>>(
      find.byType(TableCalendar<int>),
    );
    final today = DateTime.now();
    expect(calendar.firstDay.year, today.year);
    expect(calendar.firstDay.month, today.month);
    expect(calendar.firstDay.day, today.day);
    // The old screen stopped at 2025-12-31; this one always looks a year ahead.
    expect(calendar.lastDay.year, today.year + 1);
    expect(calendar.lastDay.isAfter(today), isTrue);
  });

  testWidgets('a day without availability is not selectable', (tester) async {
    final fake = _Fake();
    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');

    final calendar = tester.widget<TableCalendar<int>>(
      find.byType(TableCalendar<int>),
    );
    final isEnabled = calendar.enabledDayPredicate!;
    expect(isEnabled(DateTime.now()), isFalse);

    // No date is selected, so the slot area asks for one.
    expect(find.text('Pick a date'), findsOneWidget);
  });

  testWidgets('confirms the selected slot through POST /api/bookings once', (
    tester,
  ) async {
    final fake = _Fake(
      availability: _availabilityFromToday(40, ['10:00', '11:00']),
      lawyers: [
        {
          'id': 'lawyer-1',
          'name': 'Mona Fahmy',
          'price': '250 EGP',
          'priceValue': 250,
        },
      ],
    );

    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');

    final date = await selectAnyDate(tester);
    await tapVisible(tester, find.text('10:00 AM'));

    // Two taps before the first request finishes must still produce one booking.
    await tester.tap(find.text('Confirm Booking'));
    await tester.tap(find.text('Confirm Booking'));
    await drain(tester);

    expect(fake.bookingCalls, 1, reason: 'double submit is ignored');
    final body = fake.bookingBodies.single;
    expect(body['lawyerId'], 'lawyer-1');
    expect(body['date'], date, reason: 'the UI date is the one submitted');
    expect(body['time'], '10:00');
    expect(body['hours'], 1);
    // Success feedback comes from the server's own total price.
    expect(find.textContaining('Booking requested'), findsOneWidget);
  });

  testWidgets('offers a longer duration only when the next hour is published', (
    tester,
  ) async {
    final fake = _Fake(
      // 10:00 and 11:00 are published, 12:00 is not.
      availability: _availabilityFromToday(40, ['10:00', '11:00']),
    );

    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');
    await selectAnyDate(tester);
    await tapVisible(tester, find.text('10:00 AM'));

    expect(find.text('1 hour'), findsOneWidget);
    expect(find.text('2 hours'), findsOneWidget);
    expect(find.text('3 hours'), findsNothing);

    await tapVisible(tester, find.text('2 hours'));
    await tester.tap(find.text('Confirm Booking'));
    await drain(tester);

    expect(fake.bookingBodies.single['hours'], 2);
  });

  testWidgets('a slot the user already holds is shown as booked', (
    tester,
  ) async {
    final today = LawyerAvailability.dateKey(DateTime.now());
    final fake = _Fake(
      // Only today is available, so the selected date is the seeded one.
      availability: _availabilityFromToday(1, ['10:00', '11:00']),
      bookings: [
        {
          'id': 'bk-1',
          'lawyerId': 'lawyer-1',
          'date': today,
          'time': '10:00',
          'hours': 1,
          'status': 'Active',
        },
        {
          'id': 'bk-2',
          'lawyerId': 'lawyer-1',
          'date': today,
          'time': '11:00',
          'hours': 1,
          // A cancelled booking has released its slot on the server.
          'status': 'Cancelled',
        },
      ],
    );

    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');
    await selectAnyDate(tester);

    expect(find.text('10:00 AM (booked)'), findsOneWidget);
    expect(find.text('11:00 AM'), findsOneWidget);
    expect(find.text('11:00 AM (booked)'), findsNothing);
  });

  testWidgets('a conflict from the server is shown and the schedule reloads', (
    tester,
  ) async {
    final fake = _Fake(
      availability: _availabilityFromToday(40, ['10:00']),
      bookingStatus: 409,
      bookingMessage: 'That time was just booked. Choose another slot.',
    );

    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');
    await selectAnyDate(tester);
    await tapVisible(tester, find.text('10:00 AM'));
    await tester.tap(find.text('Confirm Booking'));
    await drain(tester);

    expect(
      find.textContaining('just booked'),
      findsOneWidget,
      reason: 'the server message is what the user sees',
    );
    expect(fake.availabilityCalls, greaterThan(1), reason: 'schedule reloaded');
  });

  testWidgets('BOOKING_OVERLAP RPC result is a friendly retryable conflict', (
    tester,
  ) async {
    final fake = _Fake(
      availability: _availabilityFromToday(40, ['10:00']),
      bookingRpcError: 'BOOKING_OVERLAP',
    );

    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');
    await selectAnyDate(tester);
    await tapVisible(tester, find.text('10:00 AM'));
    await tester.tap(find.text('Confirm Booking'));
    await drain(tester);

    expect(find.textContaining('just booked'), findsOneWidget);
    expect(fake.availabilityCalls, greaterThan(1), reason: 'schedule reloaded');
  });

  testWidgets('a failed availability request shows an error and a retry', (
    tester,
  ) async {
    final fake = _Fake(availabilityStatus: 500);
    await pumpScreen(tester, fake, lawyerId: 'lawyer-1');

    expect(find.text('Could not load availability'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('without a lawyer id it lists the real directory', (
    tester,
  ) async {
    final fake = _Fake(
      lawyers: [
        {'id': 'lawyer-1', 'name': 'Mona Fahmy', 'specialty': 'Family law'},
        {
          'id': 'lawyer-2',
          'name': 'Ahmed Hassan',
          'specialty': 'Corporate law',
        },
      ],
    );

    await pumpScreen(tester, fake);

    // The drawer opens the screen with no id; the user picks a real record
    // instead of a fabricated default.
    expect(find.text('Mona Fahmy'), findsOneWidget);
    expect(find.text('Ahmed Hassan'), findsOneWidget);
    expect(fake.availabilityCalls, 0);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('LawyerAvailability', _availabilityModelTests);
  group('AvailabilityCalendarScheduleScreen', _screenTests);
}
