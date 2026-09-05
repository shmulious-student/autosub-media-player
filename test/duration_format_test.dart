// Tests for elapsed/ETA formatting (lib/ui/duration_format.dart) + that the
// JobQueueRow surfaces them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/ui/components/job_queue_row.dart';
import 'package:autosub_media_player/ui/duration_format.dart';
import 'package:autosub_media_player/ui/tokens.dart';

void main() {
  test('fmtElapsed renders m:ss and h:mm:ss', () {
    expect(fmtElapsed(const Duration(seconds: 75)), '1:15');
    expect(
      fmtElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });

  test('fmtEta is human and rounds up partial minutes', () {
    expect(fmtEta(const Duration(seconds: 40)), '~40s left');
    expect(fmtEta(const Duration(seconds: 110)), '~2m left'); // rounds up
    expect(fmtEta(const Duration(hours: 1, minutes: 5)), '~1h 5m left');
  });

  test('fmtLocalJobTime shows local clock and date for older entries', () {
    final now = DateTime(2026, 6, 22, 12);
    expect(
      fmtLocalJobTime(DateTime(2026, 6, 22, 10, 9, 8), now: now),
      '10:09:08',
    );
    expect(
      fmtLocalJobTime(DateTime(2026, 6, 21, 23, 59, 1), now: now),
      'Jun 21 23:59:01',
    );
  });

  testWidgets('JobQueueRow shows elapsed + ETA while running', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: JobQueueRow(
            title: 'Foundation S2·E2',
            style: StatusStyles.running,
            stage: 'translate',
            progress: 0.62,
            elapsed: const Duration(minutes: 2, seconds: 14),
            eta: const Duration(minutes: 5),
          ),
        ),
      ),
    );
    expect(find.textContaining('2:14'), findsOneWidget);
    expect(find.textContaining('~5m left'), findsOneWidget);
  });
}
