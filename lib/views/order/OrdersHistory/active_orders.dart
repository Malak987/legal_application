import 'package:flutter/material.dart';

import '../../../constants/colors.dart';
import '../../../services/api_client.dart';
import '../../../state/session_scope.dart';
import '../../../widgets/customapp_bar.dart';

/// Current bookings loaded from the caller-scoped bookings API.
class ActiveOrders extends StatefulWidget {
  const ActiveOrders({super.key});

  @override
  State<ActiveOrders> createState() => _ActiveOrdersState();
}

class _ActiveOrdersState extends State<ActiveOrders> {
  late Future<List<Map<String, dynamic>>> _bookings;
  bool _loaded = false;
  final Set<String> _cancelling = <String>{};

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
    final future = SessionScope.read(context).repository.fetchBookings().then(
          (rows) => rows.where(_isCurrent).toList(growable: false),
        );
    setState(() {
      _bookings = future;
    });
    return future.then<void>((_) {}, onError: (_) {});
  }

  static bool _isCurrent(Map<String, dynamic> booking) {
    final status = _text(booking['status']).toLowerCase();
    return status != 'completed' && status != 'cancelled';
  }

  Future<void> _cancel(Map<String, dynamic> booking) async {
    final id = _text(booking['id']);
    if (id.isEmpty) {
      _showMessage('This booking has no usable ID and cannot be cancelled.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: const Text('This will cancel the selected appointment.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep booking'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cancelling.add(id));
    try {
      await SessionScope.read(context)
          .repository
          .updateBookingStatus(id, 'Cancelled');
      if (!mounted) return;
      _showMessage('Booking cancelled.');
      await _reload();
    } catch (error) {
      if (!mounted) return;
      final message = error is ApiException ? error.message : 'Please try again.';
      _showMessage('Could not cancel booking: $message');
    } finally {
      if (mounted) setState(() => _cancelling.remove(id));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
              const CustomAppBar(text: 'Active Bookings', text1: ''),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _bookings,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      final error = snapshot.error;
                      final detail = error is ApiException
                          ? error.message
                          : 'Please try again.';
                      return _BookingMessage(
                        icon: Icons.error_outline,
                        title: 'Could not load bookings',
                        detail: detail,
                        onRetry: _reload,
                      );
                    }

                    final bookings =
                        snapshot.data ?? const <Map<String, dynamic>>[];
                    if (bookings.isEmpty) {
                      return const _BookingMessage(
                        icon: Icons.event_available_outlined,
                        title: 'No active bookings',
                        detail: 'New and upcoming appointments will appear here.',
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: bookings.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final booking = bookings[index];
                          final id = _text(booking['id']);
                          final status = _text(booking['status']);
                          final isCancelling = _cancelling.contains(id);
                          return Card(
                            color: Colors.white,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: [
                                  _BookingSummary(booking: booking),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Chip(
                                        label: Text(status.isEmpty ? 'Status unknown' : status),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      const Spacer(),
                                      TextButton.icon(
                                        onPressed: isCancelling
                                            ? null
                                            : () => _cancel(booking),
                                        icon: isCancelling
                                            ? const SizedBox(
                                                height: 16,
                                                width: 16,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              )
                                            : const Icon(Icons.event_busy_outlined),
                                        label: const Text('Cancel'),
                                      ),
                                    ],
                                  ),
                                ],
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

class _BookingSummary extends StatelessWidget {
  const _BookingSummary({required this.booking});

  final Map<String, dynamic> booking;

  @override
  Widget build(BuildContext context) {
    final lawyerName = _text(booking['lawyerName']);
    final date = _text(booking['date']);
    final time = _text(booking['time']);
    final dateTime = [date, time].where((value) => value.isNotEmpty).join(' • ');
    final hours = _text(booking['hours']);
    final price = _text(booking['totalPrice']);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CircleAvatar(
          backgroundColor: AppColors.bgColor,
          child: Icon(Icons.person_outline, color: AppColors.buttonColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                lawyerName.isEmpty ? 'Lawyer' : lawyerName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (dateTime.isNotEmpty) Text(dateTime),
              if (hours.isNotEmpty || price.isNotEmpty)
                Text([
                  if (hours.isNotEmpty) '${hours}h',
                  if (price.isNotEmpty) '\$$price',
                ].join(' • ')),
            ],
          ),
        ),
      ],
    );
  }
}

class _BookingMessage extends StatelessWidget {
  const _BookingMessage({
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
