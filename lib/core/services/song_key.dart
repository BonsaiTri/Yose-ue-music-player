/// Normalized comparison key for song titles and artist names:
/// lowercase, punctuation-free, with short trailing parentheticals like
/// "(official music video)" or "(live)" removed.
///
/// Used by the download engine (duplicate prevention) and the library
/// duplicate cleanup so both agree on what "the same song" means.
String songKey(String raw) {
  var s = raw.trim().toLowerCase();
  // Strip a short trailing parenthetical/bracket suffix.
  final close = s.lastIndexOf(RegExp(r'[)\]]'));
  if (close >= 1 && close == s.length - 1) {
    final openParen = s.lastIndexOf('(', close);
    final openBracket = s.lastIndexOf('[', close);
    final openAt = openParen > openBracket ? openParen : openBracket;
    if (openAt > 0 && close - openAt <= 40) s = s.substring(0, openAt);
  }
  s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), '');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
