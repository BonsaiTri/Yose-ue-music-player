import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';

/// Sample of real yt-dlp `--dump-json --flat-playlist` output for a
/// `ytsearch3:…` query (NDJSON: one JSON object per line).
const _ndJson = '''
{"_type": "url", "ie_key": "Youtube", "id": "K0HSD_i2DvA", "url": "https://www.youtube.com/watch?v=K0HSD_i2DvA", "title": "Daft Punk - Around The World (Official Music Video Remastered)", "channel": "Daft Punk", "thumbnails": [{"url": "https://i.ytimg.com/vi/K0HSD_i2DvA/hq720.jpg?sqp=-oaymwEc", "height": 202, "width": 360}]}
{"_type": "url", "ie_key": "Youtube", "id": "dwDns8x3Jb4", "url": "https://www.youtube.com/watch?v=dwDns8x3Jb4", "title": "Daft Punk - Around the World (Official Audio)", "channel": "Daft Punk", "thumbnails": [{"url": "https://i.ytimg.com/vi/dwDns8x3Jb4/hq720.jpg?sqp=-oaymwEc", "height": 202, "width": 360}]}
{"_type": "url", "ie_key": "Youtube", "id": "ARfJ55bUAw0", "url": "https://www.youtube.com/watch?v=ARfJ55bUAw0", "title": "Around the World (Radio Edit)", "channel": "Daft Punk", "thumbnails": [{"url": "https://i.ytimg.com/vi/ARfJ55bUAw0/hq720.jpg?sqp=-oaymwEc", "height": 202, "width": 360}]}
''';

void main() {
  test('parses ytsearch NDJSON output (real shape from yt-dlp 2026.10.26)', () {
    final entries = parseYtDlpListing(_ndJson);
    expect(entries.length, 3);
    expect(entries.first.id, 'K0HSD_i2DvA');
    expect(entries.first.title,
        'Daft Punk - Around The World (Official Music Video Remastered)');
    expect(entries.first.channel, 'Daft Punk');
    // Flat search entries carry thumbnails[] instead of a top-level
    // thumbnail; the parser must fall back to the first thumbnail.
    expect(entries.first.thumbnail, isNotNull);
    expect(entries.first.thumbnail,
        startsWith('https://i.ytimg.com/vi/K0HSD_i2DvA/'));
  });
}
