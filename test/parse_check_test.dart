import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';

void main() {
  test('parse real ytsearch NDJSON output', () {
    final raw = File('/tmp/yt_search_test.json').readAsStringSync();
    final entries = parseYtDlpListing(raw);
    print('parsed ${entries.length} entries');
    for (final e in entries) {
      print('  id=${e.id} title="${e.title}" channel=${e.channel} thumb=${e.thumbnail?.substring(0, 60)}...');
    }
    expect(entries.length, 3);
    expect(entries.first.id, 'K0HSD_i2DvA');
    expect(entries.first.channel, 'Daft Punk');
    expect(entries.first.thumbnail, isNotNull);
  });
}
