import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/main.dart';

void main() {
  testWidgets('App builds without error', (WidgetTester tester) async {
    // Build the app and trigger a frame
    await tester.pumpWidget(const NaturalFarmingChatApp());

    // Verify the app shows loading screen on startup
    expect(find.text('Natural Farming Chat'), findsOneWidget);
  });
}
