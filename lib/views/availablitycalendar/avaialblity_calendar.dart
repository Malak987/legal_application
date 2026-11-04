import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../constants/colors.dart';
import '../../models/lawyer_availability.dart';
import '../../models/product_model.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';

/// Pick a date and a time from a lawyer's published availability, then book it.
///
/// WHAT THIS SCREEN USED TO BE
/// ---------------------------
/// A hardcoded `Map<DateTime, List<String>>` of September 2024 slots, a calendar
/// that refused to scroll past 31 December 2025, and a "Confirm Booking" button
/// whose `onTap` was empty. Nothing was read from or written to the backend.
///
/// WHAT IT IS NOW
/// --------------
/// * Availability comes from the public Supabase `availability` query — the lawyer's
///   real published schedule, in whatever time notation was stored.
/// * The calendar starts today and runs twelve months forward, so it no longer
///   expires.
/// * Days without availability cannot be selected; slots the signed-in user has
///   already booked are shown as taken.
/// * "Confirm Booking" calls the authenticated `rpc_create_booking` workflow through `AppRepository`, which
///   is the only path that may create a booking: the server re-checks the slot,
///   derives the price from the lawyer's rate and reserves the slot atomically.
///
/// WHAT THE CLIENT CANNOT KNOW
/// ---------------------------
/// Bookings are scoped to their owner, so another client's appointment is not
/// visible here. A slot that somebody else just took still looks free until the
/// server answers `409`, which is why that response is handled explicitly:
/// the message is shown and the schedule is reloaded.
class AvailabilityCalendarScheduleScreen extends StatefulWidget {
  const AvailabilityCalendarScheduleScreen({
    super.key,
    this.lawyerId,
    this.lawyerName,
  });

  /// The lawyer whose schedule to show.
  ///
  /// Optional because the drawer opens this screen without one. When it is
  /// absent the screen asks the user to choose a lawyer from the real
  /// directory first, so the booking always carries a genuine document id.
  final String? lawyerId;

  /// Display name for [lawyerId], when the caller already knows it.
  final String? lawyerName;

  @override
  State<AvailabilityCalendarScheduleScreen> createState() =>
      AvailabilityCalendarScheduleScreenState();
}

class AvailabilityCalendarScheduleScreenState
    extends State<AvailabilityCalendarScheduleScreen> {
  /// How far ahead the calendar may be used. A fixed end date is what made the
  /// old screen expire; this is recomputed from "today" instead.
  static const int calendarMonthsAhead = 12;

  /// The backend accepts 1–12 hours for one appointment.
  static const int maxHours = 12;

  /// Height reserved for the calendar.
  ///
  /// `TableCalendar` is built on a `PageView`, and a `PageView` cannot lay out
  /// inside a scroll view — it needs a bounded height, otherwise it throws
  /// "Vertical viewport was given unbounded height" and no day cells exist to
  /// tap. Room for the header, the weekday row and six weeks of days.
  static const double calendarHeight = 320;

  // ---- chosen lawyer -------------------------------------------------------
  String? _lawyerId;
  String? _lawyerName;
  Product? _lawyer;

  // ---- lawyer picker (only used when no lawyerId was supplied) ------------
  List<Product> _lawyers = const <Product>[];
  bool _loadingLawyers = true;
  String? _lawyersError;

  // ---- schedule ------------------------------------------------------------
  Map<String, List<int>> _slotsByDate = const <String, List<int>>{};

  /// Slot start times the signed-in user already holds on that date.
  Set<String> _mineByDate = const <String>{};
  bool _loading = true;
  String? _error;

  // ---- selection -----------------------------------------------------------
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDate;
  int? _selectedMinutes;
  int _hours = 1;

  bool _submitting = false;

  /// Guards against an older, slower response overwriting a newer one.
  int _requestSeq = 0;

  /// Set once the first load has been started, so `didChangeDependencies` does
  /// not fire a second request every time the widget is rebuilt.
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    // Deferred to after the first frame: `didChangeDependencies` runs inside
    // the build phase, where the first `setState` of a load would throw. The
    // screen is already showing its spinner, so nothing flashes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final injected = widget.lawyerId;
      if (injected != null && injected.isNotEmpty) {
        _lawyerId = injected;
        _lawyerName = widget.lawyerName;
        _loadSchedule();
      } else {
        _loadLawyers();
      }
    });
  }

  // ---------------------------------------------------------------------------
  //  Loading
  // ---------------------------------------------------------------------------

  /// The directory, for the "choose a lawyer" step.
  Future<void> _loadLawyers() async {
    final repository = SessionScope.read(context).repository;
    final seq = ++_requestSeq;
    setState(() {
      _loadingLawyers = true;
      _lawyersError = null;
    });

    try {
      final lawyers = await repository.fetchLawyers();
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _lawyers = lawyers;
        _loadingLawyers = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _lawyersError = e.message;
        _loadingLawyers = false;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _lawyersError =
            'Could not load the lawyer directory. Check your connection and retry.';
        _loadingLawyers = false;
      });
    }
  }

  /// Loads the chosen lawyer's published availability and the caller's own
  /// upcoming bookings, then renders both.
  Future<void> _loadSchedule() async {
    final lawyerId = _lawyerId;
    if (lawyerId == null || lawyerId.isEmpty) return;

    final session = SessionScope.read(context);
    final repository = session.repository;
    final seq = ++_requestSeq;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // The lawyer document supplies the rate shown next to the total. It is
      // fetched only when the caller did not already hand us one.
      final lawyer = _lawyer ?? await repository.fetchLawyer(lawyerId);

      final availability = await repository.fetchAvailability(lawyerId);
      if (!mounted || seq != _requestSeq) return;

      final byDate = <String, List<int>>{};
      for (final row in availability) {
        if (row.slots.isEmpty) continue;
        final key = row.date;
        final merged = <int>{...?byDate[key], ...row.slots}.toList()..sort();
        byDate[key] = merged;
      }

      // A failed booking read must not blank the schedule: a signed-out user
      // can still browse availability, they just cannot book.
      Set<String> mine = <String>{};
      if (session.isSignedIn) {
        try {
          final bookings = await repository.fetchBookings();
          if (!mounted || seq != _requestSeq) return;
          mine = _heldSlots(bookings, byDate);
        } on ApiException {
          // Ignored on purpose: see above.
        }
      }

      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _lawyer = lawyer;
        if (lawyer != null && (lawyer.name).isNotEmpty) {
          _lawyerName = lawyer.name;
        }
        _slotsByDate = byDate;
        _mineByDate = mine;
        _loading = false;
        _selectedMinutes = null;
        _hours = 1;
        // Keep the user on their date if it survived the reload.
        final selected = _selectedDate;
        if (selected != null &&
            (byDate[LawyerAvailability.dateKey(selected)] ?? const <int>[])
                .isEmpty) {
          _selectedDate = null;
        }
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _error =
            'Could not load availability. Check your connection and retry.';
        _loading = false;
      });
    }
  }

  /// The slots of `byDate` that `bookings` already occupy for this lawyer.
  ///
  /// Only statuses that still hold the appointment count: a cancelled booking
  /// has released its slot on the server (see `releaseLocks`), so it is not
  /// shown as taken.
  Set<String> _heldSlots(
    List<Map<String, dynamic>> bookings,
    Map<String, List<int>> byDate,
  ) {
    final held = <String>{};
    final lawyerId = _lawyerId;

    for (final booking in bookings) {
      if (booking['lawyerId']?.toString() != lawyerId) continue;
      if (booking['status']?.toString() == 'Cancelled') continue;

      final date = booking['date']?.toString() ?? '';
      final slots = byDate[date];
      if (slots == null || slots.isEmpty) continue;

      final start = LawyerAvailability.parseClockTime(
        booking['time']?.toString() ?? '',
      );
      if (start == null) continue;

      final hours = (booking['hours'] as num?)?.toInt() ?? 1;
      final end = start + hours * 60;
      for (final slot in slots) {
        if (slot >= start && slot < end) held.add('$date|$slot');
      }
    }
    return held;
  }

  // ---------------------------------------------------------------------------
  //  Selection helpers
  // ---------------------------------------------------------------------------

  List<int> _slotsOn(DateTime day) =>
      _slotsByDate[LawyerAvailability.dateKey(day)] ?? const <int>[];

  bool _isHeld(DateTime day, int minutes) =>
      _mineByDate.contains('${LawyerAvailability.dateKey(day)}|$minutes');

  bool _hasAvailability(DateTime day) => _slotsOn(day).isNotEmpty;

  /// How many hours may be booked from [start] on [day].
  ///
  /// The backend only requires the *start* to be an advertised slot and reserves
  /// the advertised slots the appointment spans, so it would accept a duration
  /// that runs past the last published slot — the data model has no closing
  /// time to check against. The UI stays conservative: a duration is offered
  /// only while every hour it covers is still published and free, which cannot
  /// produce an appointment the lawyer never advertised.
  int _maxHoursFor(DateTime day, int start) {
    final slots = _slotsOn(day).toSet();
    var max = 1;
    while (max < maxHours) {
      final next = start + max * 60;
      if (!slots.contains(next) || _isHeld(day, next)) break;
      max++;
    }
    return max;
  }

  int? get _estimatedTotal {
    final rate = _lawyer?.priceValue;
    if (rate == null || _selectedMinutes == null) return null;
    return (rate * _hours).round();
  }

  Future<void> _confirm() async {
    // A second tap while the request is in flight must not create a second
    // booking; the server would treat it as a different request.
    if (_submitting) return;

    final session = SessionScope.read(context);
    final day = _selectedDate;
    final start = _selectedMinutes;
    final lawyerId = _lawyerId;

    if (!session.isSignedIn) {
      _showMessage('Sign in to book an appointment.');
      return;
    }
    if (day == null || start == null || lawyerId == null) {
      _showMessage('Choose a date and a time first.');
      return;
    }

    setState(() => _submitting = true);
    try {
      final created = await session.repository.createBooking(
        lawyerId: lawyerId,
        lawyerName: _lawyerName ?? _lawyer?.name ?? '',
        date: LawyerAvailability.dateKey(day),
        time: LawyerAvailability.apiTime(start),
        hours: _hours,
      );

      if (!mounted) return;
      final price = (created['totalPrice'] as num?)?.toStringAsFixed(0);
      _showMessage(
        price == null
            ? 'Booking requested.'
            : 'Booking requested. Total: $price.',
      );
      // The server is authoritative: reload so anything it now considers taken
      // (including this booking) is reflected.
      await _loadSchedule();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 409 means somebody took the slot between the read and the write, and
      // 401/403 mean the session is no longer usable. Both are answered with
      // the server's own message.
      _showMessage(e.message);
      if (e.isConflict || e.isUnauthorized || e.isForbidden) {
        await _loadSchedule();
      }
    } catch (_) {
      if (mounted) {
        _showMessage('Could not book that slot. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  //  Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final choosingLawyer = _lawyerId == null;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13.0, vertical: 20.0),
          child: Column(
            children: [
              const CustomAppBar(text: 'Availability', text1: ''),
              const SizedBox(height: 14),
              if (choosingLawyer)
                Expanded(child: _buildLawyerPicker())
              else
                Expanded(child: _buildSchedule()),
            ],
          ),
        ),
      ),
      bottomNavigationBar: choosingLawyer ? null : _buildBottomBar(),
    );
  }

  /// Step one when the screen was opened without a lawyer (the drawer entry).
  Widget _buildLawyerPicker() {
    if (_loadingLawyers) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_lawyersError != null) {
      return _Status(
        icon: Icons.error_outline,
        title: 'Could not load lawyers',
        detail: _lawyersError!,
        onRetry: _loadLawyers,
      );
    }
    if (_lawyers.isEmpty) {
      return const _Status(
        icon: Icons.search_off,
        title: 'No lawyers listed yet',
        detail: 'Lawyers added by an administrator will appear here.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text1(text1: 'Choose a lawyer'),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: _lawyers.length,
            itemBuilder: (context, index) {
              final lawyer = _lawyers[index];
              final specialty = (lawyer.specialty ?? '').trim();
              return Card(
                color: Colors.white,
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListTile(
                  leading: const Icon(Icons.person, color: AppColors.text3Color),
                  title: Text(
                    lawyer.name.trim().isEmpty ? 'Unnamed lawyer' : lawyer.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: specialty.isEmpty ? null : Text(specialty),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    final id = lawyer.id;
                    if (id == null || id.isEmpty) return;
                    setState(() {
                      _lawyerId = id;
                      _lawyerName = lawyer.name;
                      _lawyer = lawyer;
                      _selectedDate = null;
                      _selectedMinutes = null;
                      _hours = 1;
                    });
                    _loadSchedule();
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSchedule() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Status(
        icon: Icons.error_outline,
        title: 'Could not load availability',
        detail: _error!,
        onRetry: _loadSchedule,
      );
    }

    final today = DateTime.now();
    final firstDay = DateTime(today.year, today.month, today.day);
    final lastDay = DateTime(
      today.year,
      today.month + calendarMonthsAhead,
      today.day,
    );

    // One scroll view rather than a fixed calendar above a fixed slot area:
    // a calendar is six rows tall, and on a short screen (or a large text
    // scale) the two would not both fit, producing a layout overflow.
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((_lawyerName ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                _lawyerName!,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text1Color,
                ),
              ),
            ),
          SizedBox(
            height: calendarHeight,
            child: _buildCalendar(firstDay, lastDay),
          ),
          const SizedBox(height: 14),
          _buildSlots(),
        ],
      ),
    );
  }

  Widget _buildCalendar(DateTime firstDay, DateTime lastDay) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16.0),
        boxShadow: [
          BoxShadow(
            color: Color.fromARGB((0.2 * 255).toInt(), 128, 128, 128),
            spreadRadius: 2,
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: TableCalendar<int>(
        firstDay: firstDay,
        lastDay: lastDay,
        focusedDay: _focusedDay,
        // Only days with published availability are selectable, which is what
        // stops a user from walking into a guaranteed 400 from the server.
        enabledDayPredicate: _hasAvailability,
        selectedDayPredicate: (day) =>
            _selectedDate != null && isSameDay(_selectedDate, day),
        onDaySelected: (selectedDay, focusedDay) {
          setState(() {
            _selectedDate = selectedDay;
            _focusedDay = focusedDay;
            _selectedMinutes = null;
            _hours = 1;
          });
        },
        rowHeight: 42,
        daysOfWeekHeight: 20,
        headerStyle: const HeaderStyle(
          formatButtonVisible: false,
          titleCentered: true,
          headerPadding: EdgeInsets.symmetric(vertical: 8),
        ),
        onPageChanged: (focusedDay) {
          // Kept in state so the next rebuild does not snap the calendar back
          // to the month it was opened on.
          setState(() => _focusedDay = focusedDay);
        },
        eventLoader: _slotsOn,
        calendarStyle: const CalendarStyle(
          todayDecoration: BoxDecoration(
            color: Colors.purpleAccent,
            shape: BoxShape.circle,
          ),
          selectedDecoration: BoxDecoration(
            color: Colors.deepPurpleAccent,
            shape: BoxShape.circle,
          ),
          weekendTextStyle: TextStyle(color: Colors.redAccent),
        ),
        calendarBuilders: CalendarBuilders<int>(
          markerBuilder: (context, day, events) {
            if (events.isEmpty) return null;
            return Positioned(
              bottom: 2,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: AppColors.buttonColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSlots() {
    final day = _selectedDate;

    if (day == null) {
      return const _Status(
        icon: Icons.event_available_outlined,
        title: 'Pick a date',
        detail: 'Days with a dot have published availability.',
      );
    }

    final slots = _slotsOn(day);
    if (slots.isEmpty) {
      return const _Status(
        icon: Icons.event_busy,
        title: 'No slots on this date',
        detail: 'Choose another day from the calendar.',
      );
    }

    final maxHours = _selectedMinutes == null
        ? 1
        : _maxHoursFor(day, _selectedMinutes!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Available slots for ${LawyerAvailability.dateKey(day)}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: slots.map((minutes) {
            final held = _isHeld(day, minutes);
            final selected = _selectedMinutes == minutes;

            return GestureDetector(
              // A slot the user already holds stays visible but cannot be
              // picked again; the server would refuse it with a 409 anyway.
              onTap: held
                  ? null
                  : () => setState(() {
                        _selectedMinutes = minutes;
                        _hours = 1;
                      }),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: held
                      ? Colors.grey.shade200
                      : selected
                          ? Colors.deepPurpleAccent
                          : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? Colors.deepPurpleAccent
                        : Colors.grey.shade300,
                    width: 2,
                  ),
                ),
                child: Text(
                  held
                      ? '${LawyerAvailability.label(minutes)} (booked)'
                      : LawyerAvailability.label(minutes),
                  style: TextStyle(
                    fontSize: 14,
                    color: held
                        ? Colors.grey.shade600
                        : selected
                            ? Colors.white
                            : Colors.black,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        if (_selectedMinutes != null) ...[
          const SizedBox(height: 18),
          const Text(
            'Duration',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: List.generate(maxHours, (index) {
              final hours = index + 1;
              final selected = _hours == hours;
              return ChoiceChip(
                label: Text(hours == 1 ? '1 hour' : '$hours hours'),
                selected: selected,
                onSelected: (_) => setState(() => _hours = hours),
              );
            }),
          ),
        ],
      ],
    );
  }

  Widget _buildBottomBar() {
    final ready = _selectedDate != null && _selectedMinutes != null;
    final total = _estimatedTotal;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (total != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                // Computed from the lawyer's stored hourly rate — the same
                // number the server multiplies by `hours`. The response is
                // still authoritative; this only avoids a surprise.
                'Total: $total for ${_hours == 1 ? '1 hour' : '$_hours hours'}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.text2Color,
                ),
              ),
            ),
          CustomButton(
            text: _submitting ? 'Booking…' : 'Confirm Booking',
            onTap: () {
              if (!ready || _submitting) return;
              _confirm();
            },
          ),
        ],
      ),
    );
  }
}

/// Empty/error placeholder with an optional retry action.
class _Status extends StatelessWidget {
  const _Status({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppColors.text3Color),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.text1Color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.text2Color),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
