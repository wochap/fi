import 'package:fi/src/rust/api/durations.dart' as durations;
import 'package:fi/theme/inputs.dart';

/// The core's duration grammar (`app_core::duration`), used by every [FiDurationInput].
final class RustDurationGrammar implements DurationGrammar {
  const RustDurationGrammar();

  @override
  int? parse(String text) => durations.parseDurationText(text: text);

  @override
  String format(int milliseconds) =>
      durations.formatDurationText(milliseconds: milliseconds);
}
