import 'package:flutter_test/flutter_test.dart';

import 'package:ar_flutter_example/main.dart';

void main() {
  testWidgets('example app renders its title', (tester) async {
    await tester.pumpWidget(const ArExampleApp());

    expect(find.text('AR Flutter Plugin Example'), findsOneWidget);
  });
}
