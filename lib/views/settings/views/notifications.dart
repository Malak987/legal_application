import 'package:flutter/material.dart';

import '../../../constants/colors.dart';
import '../../../services/api_client.dart';
import '../../../state/session_scope.dart';
import '../../../widgets/customapp_bar.dart';
import '../../../widgets/detailstext1.dart';
import '../../../widgets/detailstext2.dart';

/// User notifications backed by the caller-authorized Supabase `notifications`
/// query, `rpc_notification_update`, and owner-scoped deletion.
class GroceryNotifications extends StatefulWidget {
  const GroceryNotifications({super.key});

  @override
  State<GroceryNotifications> createState() => _GroceryNotificationsState();
}

class _GroceryNotificationsState extends State<GroceryNotifications> {
  List<Map<String, dynamic>> _notifications = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;
  String? _busyId;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final repo = SessionScope.read(context).repository;
    try {
      final list = await repo.fetchMyNotifications();
      if (!mounted) return;
      setState(() {
        _notifications = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load notifications. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _toggleRead(Map<String, dynamic> n) async {
    final id = n['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final currentRead = n['read'] == true;
    setState(() => _busyId = id);
    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.markNotificationRead(id, !currentRead);
      if (!mounted) return;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteNotification(String id) async {
    if (id.isEmpty) return;
    setState(() => _busyId = id);
    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repo.deleteNotification(id);
      if (!mounted) return;
      await _load();
      messenger.showSnackBar(
        const SnackBar(content: Text('Notification removed.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _markAllRead() async {
    final unread =
        _notifications.where((n) => n['read'] != true && n['id'] != null);
    if (unread.isEmpty) return;
    final repo = SessionScope.read(context).repository;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Future.wait(
        unread.map((n) => repo.markNotificationRead(n['id'].toString(), true)),
      );
      if (!mounted) return;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  IconData _iconForType(String type) {
    switch (type.toLowerCase()) {
      case 'booking':
        return Icons.calendar_today;
      case 'case':
        return Icons.folder_open;
      case 'wallet':
      case 'payment':
        return Icons.account_balance_wallet;
      case 'chat':
      case 'message':
        return Icons.chat_bubble_outline;
      default:
        return Icons.notifications_active_outlined;
    }
  }

  String _formatDate(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return '';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount =
        _notifications.where((n) => n['read'] != true).length;

    return Scaffold(
      backgroundColor: AppColors.bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CustomAppBar(text: 'Notifications', text1: ''),
              if (!_loading && _error == null && _notifications.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text2(
                      text2: unreadCount == 0
                          ? 'All caught up'
                          : '$unreadCount unread notification${unreadCount == 1 ? '' : 's'}',
                    ),
                    if (unreadCount > 0)
                      TextButton(
                        onPressed: _markAllRead,
                        child: const Text('Mark all as read'),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 46,
                color: AppColors.text3Color,
              ),
              const SizedBox(height: 12),
              const Text(
                'Could not load notifications',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.text2Color,
                ),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_notifications.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.notifications_none,
                size: 46,
                color: AppColors.text3Color,
              ),
              SizedBox(height: 12),
              Text(
                'No notifications yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 6),
              Text(
                'Updates about your bookings, cases, and account will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.text2Color),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _notifications.length,
        itemBuilder: (context, index) {
          final n = _notifications[index];
          final id = n['id']?.toString() ?? '';
          final title = (n['title']?.toString() ?? 'Notification').trim();
          final message =
              (n['content'] ?? n['message'] ?? '').toString().trim();
          final type = (n['type']?.toString() ?? 'general').trim();
          final isRead = n['read'] == true;
          final date = _formatDate(n['createdAt']);
          final isBusy = _busyId == id && id.isNotEmpty;

          return Card(
            color: isRead ? Colors.white : Colors.teal.shade50,
            margin: const EdgeInsets.only(bottom: 10),
            elevation: isRead ? 1 : 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              onTap: () => _toggleRead(n),
              leading: CircleAvatar(
                backgroundColor: isRead
                    ? Colors.grey.shade200
                    : AppColors.buttonColor.withAlpha(40),
                child: Icon(
                  _iconForType(type),
                  color: isRead ? Colors.grey.shade700 : AppColors.buttonColor,
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text1(
                      text1: title,
                      size: 15,
                    ),
                  ),
                  if (!isRead)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.buttonColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text2(text2: message),
                  ],
                  if (date.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text2(text2: date),
                  ],
                ],
              ),
              trailing: isBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: Colors.redAccent,
                      ),
                      tooltip: 'Delete notification',
                      onPressed: () => _deleteNotification(id),
                    ),
            ),
          );
        },
      ),
    );
  }
}
