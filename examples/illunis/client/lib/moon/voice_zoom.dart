/// What a spoken moon command asks for.
enum MoonZoomAction { zoomIn, zoomOut, reset }

const _phrases = <String, MoonZoomAction>{
  'zoom in': MoonZoomAction.zoomIn,
  'zoom in on the moon': MoonZoomAction.zoomIn,
  'zoom in on moon': MoonZoomAction.zoomIn,
  'zoom into the moon': MoonZoomAction.zoomIn,
  'zoom in to the moon': MoonZoomAction.zoomIn,
  'zoom out': MoonZoomAction.zoomOut,
  'zoom out on the moon': MoonZoomAction.zoomOut,
  'zoom out from the moon': MoonZoomAction.zoomOut,
  'zoom out of the moon': MoonZoomAction.zoomOut,
  'reset the moon': MoonZoomAction.reset,
  'reset moon': MoonZoomAction.reset,
  'reset the moon view': MoonZoomAction.reset,
};

final _nonLetters = RegExp(r"[^a-z' ]+");
final _spaces = RegExp(r'\s+');

/// Maps a transcript to a moon zoom action. Unknown text returns null.
MoonZoomAction? parseMoonZoom(String transcript) {
  var text = transcript
      .toLowerCase()
      .replaceAll(_nonLetters, ' ')
      .replaceAll(_spaces, ' ')
      .trim();
  for (final lead in const ['please ', 'can you ', 'could you ']) {
    if (text.startsWith(lead)) text = text.substring(lead.length);
  }
  if (text.endsWith(' please')) {
    text = text.substring(0, text.length - ' please'.length);
  }
  return _phrases[text];
}
