// Basic smoke test for the AutoSub app shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/main.dart';

void main() {
  testWidgets('Home renders with Library + Player nav', (tester) async {
    await tester.pumpWidget(const AutoSubApp());

    expect(find.text('Library'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
  });
}
