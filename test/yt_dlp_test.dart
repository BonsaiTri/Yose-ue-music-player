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
      expect(() => parseYtDlpListing('not json'), throwsFormatException);
    });
  });
}
