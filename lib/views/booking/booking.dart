import 'package:flutter/material.dart';

import '../availablitycalendar/avaialblity_calendar.dart';

/// Appointment booking screen backed by `AvailabilityCalendarScheduleScreen`.
class BookingScreen extends StatelessWidget {
  final String? lawyerId;
  final String? lawyerName;

  const BookingScreen({
    super.key,
    this.lawyerId,
    this.lawyerName,
  });

  @override
  Widget build(BuildContext context) {
    return AvailabilityCalendarScheduleScreen(
      lawyerId: lawyerId,
      lawyerName: lawyerName,
    );
  }
}
