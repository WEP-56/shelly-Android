import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:shelly_android/app/shelly_app.dart';

void main() {
  testWidgets('renders the startup state', (tester) async {
    await tester.pumpWidget(const ShellyApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
