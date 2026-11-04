/// One `availability` document: the start times a lawyer offers on one day.
///
/// The backend stores `{ lawyerId, date, slots: ['09:00', '10:30', ...] }`.
/// Two conventions exist in the data — the seed writes `'09:00 am'` while the
/// API and tests write `'09:00'` — so every slot is parsed into minutes since
/// midnight and formatted for display here. Nothing else in the app has to
/// know which form came off the wire.
class LawyerAvailability {
  const LawyerAvailability({
    required this.id,
    required this.lawyerId,
    required this.date,
    required this.slots,
  });

  final String id;
  final String lawyerId;

  /// `YYYY-MM-DD`, the format the booking API requires.
  final String date;

  /// Slot start times, in minutes since midnight, sorted and de-duplicated.
  final List<int> slots;

  bool get isEmpty => slots.isEmpty;

  static LawyerAvailability fromJson(Map<String, dynamic> json) {
    final raw = json['slots'];
    final minutes = <int>{};
    if (raw is List) {
      for (final slot in raw) {
        final parsed = parseClockTime(slot?.toString() ?? '');
        if (parsed != null) minutes.add(parsed);
      }
    }
    final sorted = minutes.toList()..sort();

    return LawyerAvailability(
      id: json['id']?.toString() ?? '',
      lawyerId: json['lawyerId']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      slots: sorted,
    );
  }

  /// Parses `'09:00'`, `'9:00'`, `'9:00 am'`, `'01:30 PM'` into minutes.
  ///
  /// Mirrors `parseClockTime` in `backend/src/utils/scheduling.js`; returns
  /// `null` for anything that is not a real time of day.
  static int? parseClockTime(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?:\s*([ap])\.?m\.?)?$')
        .firstMatch(value.trim().toLowerCase());
    if (match == null) return null;

    var hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    if (minutes > 59) return null;

    final meridiem = match.group(3);
    if (meridiem != null) {
      if (hours < 1 || hours > 12) return null;
      if (meridiem == 'p' && hours != 12) hours += 12;
      if (meridiem == 'a' && hours == 12) hours = 0;
    } else if (hours > 23) {
      return null;
    }
    return hours * 60 + minutes;
  }

  /// `'HH:MM'` — the format accepted by the booking RPC.
  static String apiTime(int minutes) {
    final hours = (minutes ~/ 60).toString().padLeft(2, '0');
    final rest = (minutes % 60).toString().padLeft(2, '0');
    return '$hours:$rest';
  }

  /// `'9:00 AM'` — how the app has always displayed a slot.
  static String label(int minutes) {
    final hour24 = minutes ~/ 60;
    final rest = (minutes % 60).toString().padLeft(2, '0');
    final suffix = hour24 < 12 ? 'AM' : 'PM';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    return '$hour12:$rest $suffix';
  }

  /// `'YYYY-MM-DD'` for a calendar day, in local time.
  ///
  /// Built by hand rather than via `DateFormat` so no locale initialisation is
  /// needed and the value cannot drift by a day through a timezone conversion:
  /// the backend stores a date, not an instant.
  static String dateKey(DateTime day) {
    final month = day.month.toString().padLeft(2, '0');
    final dayOfMonth = day.day.toString().padLeft(2, '0');
    return '${day.year}-$month-$dayOfMonth';
  }

  /// Parses `'YYYY-MM-DD'` into a local `DateTime`, or `null`.
  static DateTime? parseDateKey(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final parsed = DateTime(year, month, day);
    // Reject 2026-02-30, which DateTime would silently roll forward.
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }
}
