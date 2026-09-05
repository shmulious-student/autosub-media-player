// Smoke tests for the design-system primitives (DESIGN_SYSTEM §3/§5). These avoid
// booting the engine supervisor + media_kit so they stay fast and deterministic.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/ui/bidi.dart';
import 'package:autosub_media_player/ui/components/confidence_meter.dart';
import 'package:autosub_media_player/ui/components/empty_state.dart';
import 'package:autosub_media_player/ui/components/status_chip.dart';
import 'package:autosub_media_player/ui/tokens.dart';

Widget _host(Widget child) =>
    MaterialApp(theme: appTheme(), home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('StatusChip renders its label + spoken semantics', (tester) async {
    await tester.pumpWidget(_host(const StatusChip(
      style: StatusStyles.running,
      progress: 0.62,
      detail: 'transcribe',
    )));
    // Running + progress → "Translating · 62%".
    expect(find.text('Translating · 62%'), findsOneWidget);
  });

  testWidgets('EmptyState shows title + action', (tester) async {
    await tester.pumpWidget(_host(EmptyState(
      icon: Icons.movie_outlined,
      title: 'Your library is empty.',
      actions: [FilledButton(onPressed: () {}, child: const Text('Add a folder'))],
    )));
    expect(find.text('Your library is empty.'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('ConfidenceMeter shows the band word, not just a number',
      (tester) async {
    await tester.pumpWidget(_host(const ConfidenceMeter(value: 0.41)));
    expect(find.textContaining('Please review'), findsOneWidget);
  });

  test('directionOf infers RTL from Hebrew, LTR from Latin', () {
    expect(directionOf('שלום'), TextDirection.rtl);
    expect(directionOf('Foundation'), TextDirection.ltr);
    // Mixed: first strong char wins (Hebrew here).
    expect(directionOf('שלום Yael'), TextDirection.rtl);
  });
}
