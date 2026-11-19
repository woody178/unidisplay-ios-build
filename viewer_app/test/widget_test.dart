import 'package:flutter_test/flutter_test.dart';
import 'package:unidisplay_viewer/main.dart';

void main() {
  testWidgets('UniDisplay smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const UniDisplayApp());
    expect(find.textContaining('UniDisplay'), findsOneWidget);
  });
}
