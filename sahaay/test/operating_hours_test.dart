import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sahaay/main.dart';

void main() {
  testWidgets('records operating hours in 24-hour API format and can clear',
      (tester) async {
    OperatingHoursValue value = (from: null, to: null);
    await tester.pumpWidget(MaterialApp(
      theme: sahaayLightTheme,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => OperatingHoursFields(
            requiredForMatching: true,
            value: value,
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Opens: Choose time'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(value.from, '09:00');

    await tester.tap(find.text('Closes: Choose time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(value.to, '09:00');

    await tester.tap(find.text('Clear hours'));
    await tester.pumpAndSettle();
    expect(value, (from: null, to: null));
  });
}
