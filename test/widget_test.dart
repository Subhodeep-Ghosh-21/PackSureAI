
import 'package:flutter_test/flutter_test.dart';
import 'package:packsureai/main.dart';

void main() {
  testWidgets('PackSureAI app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const PackSureApp());

    expect(find.text('PackSureAI'), findsOneWidget);
    expect(find.text('Accessible Product Label Scanner'), findsOneWidget);
  });
}