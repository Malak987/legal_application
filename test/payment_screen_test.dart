import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legalserviceapp/views/checkout/payment_screen.dart';

void main() {
  testWidgets('legacy payment screen cannot collect card details or fake success',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: PaymentScreen()),
    );

    expect(find.text('Payments are currently unavailable'), findsOneWidget);
    expect(find.textContaining('No payment has been taken'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Proceed'), findsNothing);
    expect(find.text('Order Confirmed'), findsNothing);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Payments are currently unavailable'), findsOneWidget);
    expect(find.text('Order Confirmed'), findsNothing);
  });
}
