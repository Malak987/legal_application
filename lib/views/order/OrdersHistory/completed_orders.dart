import 'package:flutter/material.dart';

import '../../../constants/colors.dart';
import '../../../services/api_client.dart';
import '../../../state/session_scope.dart';
import '../../../widgets/custom_outline_button.dart';
import '../../../widgets/customapp_bar.dart';
import '../../../widgets/custombtn.dart';
import '../../../widgets/detailstext1.dart';
import '../../../widgets/detailstext2.dart';
import '../../availablitycalendar/avaialblity_calendar.dart';
import '../../reviews/writereview.dart';

/// Completed bookings derived from the signed-in user's Supabase bookings.
class CompletedOrders extends StatefulWidget {
  const CompletedOrders({super.key});

  @override
  CompletedOrdersState createState() => CompletedOrdersState();
}

class CompletedOrdersState extends State<CompletedOrders> {
  late Future<List<Map<String, dynamic>>> _bookings;
  bool _loaded = false;

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
    final future = SessionScope.read(context)
        .repository
        .fetchBookings(status: 'Completed')
        .then((rows) => rows.where(_isCompleted).toList());
    setState(() {
      _bookings = future;
    });
    return future.then((_) {}, onError: (_) {});
  }

  static bool _isCompleted(Map<String, dynamic> b) {
    final status = (b['status']?.toString() ?? '').toLowerCase();
    return status == 'completed';
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
              const CustomAppBar(text: 'Completed Bookings', text1: ''),
              const SizedBox(height: 20),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _bookings,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return _CompletedPlaceholder(
                        icon: Icons.error_outline,
                        title: 'Could not load completed bookings',
                        detail: snapshot.error is ApiException
                            ? (snapshot.error as ApiException).message
                            : 'Please try again.',
                        onRetry: _reload,
                      );
                    }
                    final bookings =
                        snapshot.data ?? const <Map<String, dynamic>>[];
                    if (bookings.isEmpty) {
                      return const _CompletedPlaceholder(
                        icon: Icons.event_available_outlined,
                        title: 'No completed bookings yet',
                        detail:
                            'Finished consultations will appear here so you can leave a review or re-book.',
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView.builder(
                        itemCount: bookings.length,
                        itemBuilder: (context, index) {
                          final b = bookings[index];
                          final lawyerId = b['lawyerId']?.toString() ?? '';
                          final lawyerName =
                              (b['lawyerName']?.toString() ?? '').trim();
                          final date = b['date']?.toString() ?? '';
                          final time = b['time']?.toString() ?? '';
                          final hours = b['hours']?.toString() ?? '1';
                          final price = b['totalPrice']?.toString() ?? '0';

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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 6),
                                          child: SizedBox(
                                            height: 80,
                                            width: 110,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: Image.asset(
                                                'images/lawyer2.png',
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const Center(
                                                  child: Icon(
                                                    Icons.person,
                                                    color: AppColors.text3Color,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text1(
                                                text1: lawyerName.isEmpty
                                                    ? 'Lawyer'
                                                    : lawyerName,
                                              ),
                                              Text2(
                                                text2: '$date • $time (${hours}h)',
                                              ),
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
                                          Flexible(
                                            child: CustomOutlinedButton(
                                              text: 'Rate',
                                              onTap: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        WriteReviewScreen(
                                                      initialLawyerId:
                                                          lawyerId.isEmpty
                                                              ? null
                                                              : lawyerId,
                                                      initialLawyerName:
                                                          lawyerName.isEmpty
                                                              ? null
                                                              : lawyerName,
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
                                                      lawyerId: lawyerId.isEmpty
                                                          ? null
                                                          : lawyerId,
                                                      lawyerName:
                                                          lawyerName.isEmpty
                                                              ? null
                                                              : lawyerName,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
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
}

class _CompletedPlaceholder extends StatelessWidget {
  const _CompletedPlaceholder({
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
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppColors.text3Color),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.text2Color),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
