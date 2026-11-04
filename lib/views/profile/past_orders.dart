import 'package:flutter/material.dart';

import '../../constants/colors.dart';
import '../../services/api_client.dart';
import '../../state/session_scope.dart';
import '../../widgets/custom_outline_button.dart';
import '../../widgets/customapp_bar.dart';
import '../../widgets/custombtn.dart';
import '../../widgets/detailstext1.dart';
import '../../widgets/detailstext2.dart';
import '../availablitycalendar/avaialblity_calendar.dart';
import '../reviews/writereview.dart';

/// User booking history opened from Profile -> "My Orders", backed by
/// the caller-authorized Supabase booking query.
class PastOrders extends StatefulWidget {
  const PastOrders({super.key});

  @override
  PastOrdersState createState() => PastOrdersState();
}

class PastOrdersState extends State<PastOrders> {
  late Future<List<Map<String, dynamic>>> _bookings;
  bool _loaded = false;
  String? _cancellingId;

  @override
  void initState() {
    super.initState();
    _bookings = Future.value(const <Map<String, dynamic>>[]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _reload();
  }

  Future<void> _reload() {
    final future = SessionScope.read(context).repository.fetchBookings();
    setState(() {
      _bookings = future;
    });
    return future.then((_) {}, onError: (_) {});
  }

  Future<void> _cancelBooking(String id) async {
    setState(() => _cancellingId = id);
    try {
      await SessionScope.read(context)
          .repository
          .updateBookingStatus(id, 'Cancelled');
      if (!mounted) return;
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Booking cancelled.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } finally {
      if (mounted) setState(() => _cancellingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'My Orders', text1: ''),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _bookings,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      final detail = snapshot.error is ApiException
                          ? (snapshot.error as ApiException).message
                          : 'Please try again.';
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 44,
                              color: AppColors.text3Color,
                            ),
                            const SizedBox(height: 12),
                            Text(detail, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _reload,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }

                    final all =
                        snapshot.data ?? const <Map<String, dynamic>>[];
                    if (all.isEmpty) {
                      return const Center(
                        child: Text(
                          'No bookings found yet.',
                          style: TextStyle(color: AppColors.text2Color),
                        ),
                      );
                    }

                    final active = all.where((b) {
                      final s = (b['status']?.toString() ?? '').toLowerCase();
                      return s != 'completed' && s != 'cancelled';
                    }).toList();
                    final completed = all.where((b) {
                      return (b['status']?.toString() ?? '').toLowerCase() ==
                          'completed';
                    }).toList();
                    final cancelled = all.where((b) {
                      return (b['status']?.toString() ?? '').toLowerCase() ==
                          'cancelled';
                    }).toList();

                    return RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView(
                        children: [
                          if (active.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 7),
                              child: Text(
                                'Active Bookings',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ...active.map(
                              (b) => _buildBookingCard(b, 'Active'),
                            ),
                          ],
                          if (completed.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 7),
                              child: Text(
                                'Completed Bookings',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ...completed.map(
                              (b) => _buildBookingCard(b, 'Completed'),
                            ),
                          ],
                          if (cancelled.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 7),
                              child: Text(
                                'Cancelled Bookings',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            ...cancelled.map(
                              (b) => _buildBookingCard(b, 'Cancelled'),
                            ),
                          ],
                        ],
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

  Widget _buildBookingCard(Map<String, dynamic> b, String group) {
    final id = b['id']?.toString() ?? '';
    final lawyerId = b['lawyerId']?.toString() ?? '';
    final lawyerName = (b['lawyerName']?.toString() ?? '').trim();
    final date = b['date']?.toString() ?? '';
    final time = b['time']?.toString() ?? '';
    final hours = b['hours']?.toString() ?? '1';
    final price = b['totalPrice']?.toString() ?? '0';
    final status = b['status']?.toString() ?? group;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        color: Colors.white,
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Image.asset(
                    'images/lawyer2.png',
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.person,
                      size: 48,
                      color: AppColors.text3Color,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text1(
                          text1: lawyerName.isEmpty ? 'Lawyer' : lawyerName,
                        ),
                        Text2(text2: '$date • $time (${hours}h) • $status'),
                        Text1(text1: '\$$price'),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    if (group == 'Active') ...[
                      Flexible(
                        child: _cancellingId == id
                            ? const Center(child: CircularProgressIndicator())
                            : CustomOutlinedButton(
                                text: 'Cancel Booking',
                                onTap: () {
                                  if (id.isNotEmpty) _cancelBooking(id);
                                },
                              ),
                      ),
                    ] else if (group == 'Completed') ...[
                      Flexible(
                        child: CustomOutlinedButton(
                          text: 'Rate Lawyer',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => WriteReviewScreen(
                                  initialLawyerId:
                                      lawyerId.isEmpty ? null : lawyerId,
                                  initialLawyerName:
                                      lawyerName.isEmpty ? null : lawyerName,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: CustomButton(
                          text: 'Re-Book',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    AvailabilityCalendarScheduleScreen(
                                  lawyerId: lawyerId.isEmpty ? null : lawyerId,
                                  lawyerName:
                                      lawyerName.isEmpty ? null : lawyerName,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ] else ...[
                      Flexible(
                        child: CustomButton(
                          text: 'Re-Book',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    AvailabilityCalendarScheduleScreen(
                                  lawyerId: lawyerId.isEmpty ? null : lawyerId,
                                  lawyerName:
                                      lawyerName.isEmpty ? null : lawyerName,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
