/// What the phone adds to POST /turn and POST /reply (and /reply/stream):
/// the short-term context and the top recalled long-term notes. Two extra
/// top-level body fields, `short_term` and `memories`; a server that does not
/// know them ignores them, so older Workers keep working.
library;

import 'memory_note.dart';
import 'short_term_memory.dart';

class PhoneContext {
  const PhoneContext({this.shortTerm = const ShortTermContext(), this.memories = const []});
  final ShortTermContext shortTerm;
  final List<RecalledMemory> memories;

  static const empty = PhoneContext();

  /// The extra body fields: `{short_term: {summaries, turns}, memories: [...]}`.
  Map<String, dynamic> toJson() => {
        'short_term': shortTerm.toJson(),
        'memories': [for (final m in memories) m.toJson()],
      };
}
