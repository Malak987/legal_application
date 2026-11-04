import 'package:flutter/material.dart';

import '../../../constants/colors.dart';
import '../../../services/api_client.dart';
import '../../../state/session_scope.dart';
import '../../../widgets/customapp_bar.dart';
import 'active_orders.dart';
import 'cancelled_orders.dart';
import 'completed_orders.dart';

/// Booking overview backed by the signed-in user's Supabase booking query.
class OrdersHistory extends StatefulWidget {
  const OrdersHistory({super.key});

  @override
  State<OrdersHistory> createState() => _OrdersHistoryState();
}

class _OrdersHistoryState extends State<OrdersHistory> {
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
    final future = SessionScope.read(context).repository.fetchBookings();
    setState(() {
      _bookings = future;
    });
    return future.then<void>((_) {}, onError: (_) {});
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) _reload();
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
              const CustomAppBar(text: 'My Bookings', text1: ''),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _bookings,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      final error = snapshot.error;
                      return _HistoryMessage(
                        icon: Icons.error_outline,
                        title: 'Could not load bookings',
                        detail: error is ApiException
                            ? error.message
                            : 'Please try again.',
                        onRetry: _reload,
                      );
                    }

                    final bookings =
                        snapshot.data ?? const <Map<String, dynamic>>[];
                    final active = bookings.where(_isCurrent).toList();
                    final completed = bookings.where(_isCompleted).toList();
                    final cancelled = bookings.where(_isCancelled).toList();

                    return RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          _BookingSection(
                            title: 'Active Bookings',
                            count: active.length,
                            onSeeAll: () => _open(const ActiveOrders()),
                            bookings: active.take(3).toList(),
                          ),
                          _BookingSection(
                            title: 'Completed Bookings',
                            count: completed.length,
                            onSeeAll: () => _open(const CompletedOrders()),
                            bookings: completed.take(3).toList(),
                          ),
                          _BookingSection(
                            title: 'Cancelled Bookings',
                            count: cancelled.length,
                            onSeeAll: () => _open(const CancelledOrders()),
                            bookings: cancelled.take(3).toList(),
                          ),
                          if (bookings.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'Your appointments will appear here after you book a lawyer.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.text2Color),
                              ),
                            ),
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
}

bool _isCurrent(Map<String, dynamic> booking) {
  final status = _text(booking['status']).toLowerCase();
  return status != 'completed' && status != 'cancelled';
}

bool _isCompleted(Map<String, dynamic> booking) =>
    _text(booking['status']).toLowerCase() == 'completed';

bool _isCancelled(Map<String, dynamic> booking) =>
    _text(booking['status']).toLowerCase() == 'cancelled';

class _BookingSection extends StatelessWidget {
  const _BookingSection({
    required this.title,
    required this.count,
    required this.onSeeAll,
    required this.bookings,
  });

  final String title;
  final int count;
  final VoidCallback onSeeAll;
  final List<Map<String, dynamic>> bookings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$title ($count)',
                  style: const TextStyle(
                    color: AppColors.text1Color,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(onPressed: onSeeAll, child: const Text('See all')),
            ],
          ),
        ),
        if (bookings.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
            child: Text('No bookings in this section.',
                style: TextStyle(color: AppColors.text2Color)),
          )
        else
          ...bookings.map((booking) => _BookingPreview(booking: booking)),
      ],
    );
  }
}

class _BookingPreview extends StatelessWidget {
  const _BookingPreview({required this.booking});

  final Map<String, dynamic> booking;

  @override
  Widget build(BuildContext context) {
    final name = _text(booking['lawyerName']);
    final date = _text(booking['date']);
    final time = _text(booking['time']);
    final status = _text(booking['status']);
    final amount = _text(booking['totalPrice']);
    final schedule = [date, time].where((value) => value.isNotEmpty).join(' • ');
    return Card(
      margin: const EdgeInsets.only(bottom: 7),
      color: Colors.white,
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: AppColors.bgColor,
          child: Icon(Icons.person_outline, color: AppColors.buttonColor),
        ),
        title: Text(name.isEmpty ? 'Lawyer' : name),
        subtitle: Text([
          if (schedule.isNotEmpty) schedule,
          if (status.isNotEmpty) status,
        ].join(' • ')),
        trailing: amount.isEmpty ? null : Text('\$$amount'),
      ),
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage({
    required this.icon,
    required this.title,
    required this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppColors.text3Color),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _text(dynamic value) => value?.toString().trim() ?? '';
