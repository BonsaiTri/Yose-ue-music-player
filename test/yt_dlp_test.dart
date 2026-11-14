import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/features/downloader/domain/yt_dlp.dart';

void main() {
  group('parseYtDlpListing', () {
    test('single video object (no --flat-playlist shape)', () {
      final stdout = jsonEncode({
        'id': 'fBgKxsvl6M8',
        'title': 'All Eyes On Me (Song Only)',
        'uploader': 'Bo Burnham - Topic',
      });
      final entries = parseYtDlpListing(stdout);
      expect(entries, hasLength(1));
      expect(entries.single.id, 'fBgKxsvl6M8');
      expect(entries.single.title, 'All Eyes On Me (Song Only)');
      expect(entries.single.channel, 'Bo Burnham - Topic');
    });

    test('flat playlist emits a top-level array of entry objects', () {
      final stdout = jsonEncode([
        {'id': 'aaaaaaaaaaa', 'title': 'First Song', 'url': 'https://youtu.be/aaaaaaaaaaa'},
        {'id': 'bbbbbbbbbbb', 'title': 'Second Song', 'url': 'https://youtu.be/bbbbbbbbbbb'},
        {'id': null, 'title': 'Broken entry'},
      ]);
      final entries = parseYtDlpListing(stdout);
      expect(entries.map((e) => e.id), ['aaaaaaaaaaa', 'bbbbbbbbbbb']);
      expect(entries.map((e) => e.title), ['First Song', 'Second Song']);
    });

    test('full playlist object uses its entries array', () {
      final stdout = jsonEncode({
        'id': 'PL8_b2d0WTcErfeETzJGV88mOOkHvAdQoL',
        'title': 'Some playlist',
        'entries': [
          {'id': 'ccccccccccc', 'title': 'Third Song', 'uploader': 'Someone'},
        ],
      });
      final entries = parseYtDlpListing(stdout);
      expect(entries, hasLength(1));
      expect(entries.single.id, 'ccccccccccc');
      expect(entries.single.channel, 'Someone');
    });

    test('garbage output yields an empty list, not an exception', () {
      expect(parseYtDlpListing('{}'), isEmpty);
      expect(parseYtDlpListing('not json'), isEmpty);
      expect(parseYtDlpListing(''), isEmpty);
    });

    test('line-delimited JSON (modern playlist API) parses every entry', () {
      // yt-dlp emits one JSON object per line for some playlist types
      // (observed with a 187-track playlist).
      final stdout = [
        jsonEncode({
          'id': 'fBgKxsvl6M8',
          'title': 'All Eyes On Me (Song Only)',
          'uploader': 'Bo Burnham - Topic',
          'thumbnail': 'https://i.ytimg.com/vi/fBgKxsvl6M8/hqdefault.jpg',
        }),
        jsonEncode({
          'id': 'DPe2diiGJRE',
          'title': 'Wellerman (Sea Shanty)',
          'uploader': 'The Longest Time',
        }),
        jsonEncode({'id': 'YDXaXDU_3Wc', 'title': "C'est la vie"}),
      ].join('\n');
      final entries = parseYtDlpListing(stdout);
      expect(entries.map((e) => e.id), [
        'fBgKxsvl6M8',
        'DPe2diiGJRE',
        'YDXaXDU_3Wc',
      ]);
      expect(entries.first.thumbnail, isNotNull);
    });

    test('flat entries use the thumbnails array (no top-level thumbnail)', () {
      final stdout = jsonEncode([
        {
          'id': 'fBgKxsvl6M8',
          'title': 'All Eyes On Me (Song Only)',
          'uploader': 'boburnham',
          'thumbnails': [
            {'url': 'https://i.ytimg.com/vi/fBgKxsvl6M8/hqdefault.jpg', 'width': 168, 'height': 94},
            {'url': 'https://i.ytimg.com/vi/fBgKxsvl6M8/hq720.jpg', 'width': 720, 'height': 270},
          ],
        },
      ]);
      final entries = parseYtDlpListing(stdout);
      expect(entries.single.thumbnail, contains('i.ytimg.com'));
      expect(entries.single.channel, 'boburnham');
    });

    test('NDJSON with interleaved warning lines and duplicates is tolerated',
        () {
      final stdout = [
        'WARNING: [youtube] some warning noise',
        jsonEncode({'id': 'aaaaaaaaaaa', 'title': 'First Song'}),
        'ERROR: [youtube] bbbbbbbbbbb: unable to extract (skipped)',
        jsonEncode({'id': 'bbbbbbbbbbb', 'title': 'Second Song'}),
        jsonEncode({'id': 'bbbbbbbbbbb', 'title': 'Second Song (duplicate)'}),
        jsonEncode({'title': 'entry without id'}),
        '',
      ].join('\n');
      final entries = parseYtDlpListing(stdout);
      expect(entries.map((e) => e.id), ['aaaaaaaaaaa', 'bbbbbbbbbbb']);
      expect(entries.map((e) => e.title), ['First Song', 'Second Song']);
    });
  });
}
