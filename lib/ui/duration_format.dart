// Duration formatting for elapsed time + ETA in the processing UI. Times are
// rendered with Western digits in a pinned-LTR context (RTL.md §4.4).

/// Clock form for elapsed time: "m:ss" or "h:mm:ss".
String fmtElapsed(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Human ETA: "~5m left", "~1h 5m left", "~40s left".
String fmtEta(Duration d) {
  if (d.inHours >= 1) {
    final m = d.inMinutes.remainder(60);
    return m > 0 ? '~${d.inHours}h ${m}m left' : '~${d.inHours}h left';
  }
  if (d.inMinutes >= 1) {
    final s = d.inSeconds.remainder(60);
    // Round up to the next minute when there are leftover seconds, so a job never
    // shows "~1m left" for 110s.
    final m = s > 0 ? d.inMinutes + 1 : d.inMinutes;
    return '~${m}m left';
  }
  final s = d.inSeconds < 5 ? 5 : ((d.inSeconds + 4) ~/ 5) * 5; // round to 5s
  return '~${s}s left';
}

/// Local clock for job history timestamps. Shows time for today's jobs and adds
/// a date for older entries (history is capped at three days).
String fmtLocalJobTime(DateTime local, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  if (local.year == ref.year &&
      local.month == ref.month &&
      local.day == ref.day) {
    return clock;
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[local.month - 1]} ${local.day} $clock';
}
