import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/engine/engine_client.dart';

void main() {
  test('EngineJob parses UTC history timestamps and rating', () {
    final job = EngineJob.fromJson({
      'id': 'j1',
      'path': '/m/A.mkv',
      'target': 'he',
      'state': 'done',
      'progress': 1.0,
      'queuedAtUtcMs': 1782100000000,
      'startedAtUtcMs': 1782100005000,
      'endedAtUtcMs': 1782100065000,
      'durationMs': 60000,
      'rating': {'score': 92, 'label': 'Great', 'summary': 'Clean QA pass'},
    });

    expect(job.queuedAtUtc.isUtc, isTrue);
    expect(job.startedAtUtc?.isUtc, isTrue);
    expect(job.endedAtUtc?.isUtc, isTrue);
    expect(job.finishedDuration, const Duration(minutes: 1));
    expect(job.rating?.score, 92);
    expect(job.rating?.label, 'Great');
  });
}
