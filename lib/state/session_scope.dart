import 'package:flutter/widgets.dart';

import 'session_controller.dart';

/// Makes the app-wide [SessionController] available to the widget tree.
///
/// An [InheritedNotifier] rather than a third-party state package: the app
/// already depends on Flutter only, and this keeps the dependency count
/// unchanged while giving every screen one shared source of auth truth.
class SessionScope extends InheritedNotifier<SessionController> {
  const SessionScope({
    super.key,
    required SessionController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Subscribing accessor — use in `build()` so the widget rebuilds when the
  /// session changes.
  static SessionController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(
      scope?.notifier != null,
      'No SessionScope found. Wrap the app in SessionScope.',
    );
    return scope!.notifier!;
  }

  /// Non-subscribing accessor — safe from event handlers, `initState` and
  /// async callbacks.
  static SessionController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SessionScope>();
    assert(
      scope?.notifier != null,
      'No SessionScope found. Wrap the app in SessionScope.',
    );
    return scope!.notifier!;
  }

  /// Returns `null` instead of asserting, for widgets that may be used outside
  /// the app shell (previews, isolated tests).
  static SessionController? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SessionScope>()?.notifier;
}
