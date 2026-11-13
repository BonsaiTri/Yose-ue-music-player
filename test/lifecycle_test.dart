// M5 lifecycle and reliability tests:
//  - `flushState()` persists immediately (no-op safety with an empty queue)
//  - `PlaybackStateRecord` JSON round-trips (the on-disk contract)
//  - the app root observes lifecycle changes; `detached` triggers a flush
//    without breaking the tree.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show driftRuntimeOptions;

import 'package:music_player/app/app.dart';
import 'package:music_player/database/database.dart';
import 'package:music_player/database/repositories/library_repository.dart';
import 'package:music_player/features/player/domain/playback_controller.dart';

import 'smoke_test.dart' show makeContainer;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('flushState with an empty queue is a safe no-op', () async {
    final temp = await Directory.systemTemp.createTemp('lifecycle_');
    try {
      final db = AppDatabase.withFile(File(p.join(temp.path, 't.sqlite')));
      try {
        final player = PlaybackController(
            stateDir: temp.path, tracksRepo: TrackRepository(db));
        await player.flushState();
        expect(File(p.join(temp.path, 'playback_state.json')).existsSync(),
            isFalse);
      } finally {
        await db.close();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('PlaybackStateRecord survives a JSON round trip', () {
    final record = PlaybackStateRecord(
      trackId: 'a' * 36,
      positionMs: 123456,
      queueIds: List.filled(3, 'b' * 36),
      index: 1,
      shuffle: true,
      repeatMode: PlayerRepeatMode.all.name,
    );
    final decoded = PlaybackStateRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>);
    expect(decoded, isNotNull);
    expect(decoded!.trackId, 'a' * 36);
    expect(decoded.positionMs, 123456);
    expect(decoded.queueIds, ['b' * 36, 'b' * 36, 'b' * 36]);
    expect(decoded.index, 1);
    expect(decoded.shuffle, isTrue);
    expect(decoded.repeatMode, 'all');
  });

  test('PlaybackStateRecord.fromJson returns null for empty/absent records',
      () {
    expect(PlaybackStateRecord.fromJson(null), isNull);
    expect(PlaybackStateRecord.fromJson({}), isNull);
    expect(
        PlaybackStateRecord.fromJson({
          'trackId': 'a' * 36,
          'queueIds': <String>[],
        }),
        isNull);
  });

  test('corrupted-type payloads throw (caught by restore\'s try/catch)', () {
    expect(
        () => PlaybackStateRecord.fromJson({
              'trackId': 42, // wrong type
              'queueIds': 'not-a-list',
            }),
        throwsA(isA<TypeError>()));
  });

  testWidgets('app root survives all lifecycle transitions incl. detached',
      (tester) async {
    final container = (await tester.runAsync(() => makeContainer()))!;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
          container: container, child: const MusicPlayerApp()),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(MaterialApp), findsOneWidget);

    final state =
        tester.state(find.byType(MusicPlayerApp)) as WidgetsBindingObserver;
    // Exercise every lifecycle transition; `detached` fires the flush path.
    state.didChangeAppLifecycleState(AppLifecycleState.inactive);
    state.didChangeAppLifecycleState(AppLifecycleState.hidden);
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
    state.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Tree is still intact after teardown signaling.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
