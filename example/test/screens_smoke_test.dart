// Smoke tests that mount each demo screen against a real database in a
// temporary directory, exercising the open/build/dispose path end to end.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:reaxdb_example/main.dart';
import 'package:reaxdb_example/screens/iteration_demo_screen.dart';
import 'package:reaxdb_example/services/database_service.dart';

/// Alternates fake-async frames with real event-loop turns so file I/O
/// started by a screen can finish while the widget tree keeps rendering.
Future<void> settle(WidgetTester tester, {int rounds = 400}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reaxdb_example_screens');
    DatabaseService.documentsDirectory = () async => root;
  });

  tearDown(() async {
    await ReaxDB.closeAll();
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets(
    timeout: const Timeout(Duration(minutes: 1)),
    'the iteration demo runs every scan it offers',
    (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: IterationDemoScreen()));
      await settle(tester);

      for (final String label in <String>[
        'scanPrefix',
        'keys',
        'range',
        'reverse + limit',
        'aggregate',
      ]) {
        await tester.tap(find.widgetWithText(FilledButton, label));
        await settle(tester, rounds: 100);
        expect(tester.takeException(), isNull, reason: label);
      }

      expect(find.textContaining('city:london'), findsWidgets);
      expect(find.textContaining('Largest: london'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, rounds: 50);
    },
  );

  for (final Demo demo in demos) {
    testWidgets(
      timeout: const Timeout(Duration(minutes: 1)),
      '${demo.title} opens and closes cleanly',
      (WidgetTester tester) async {
        // A phone-sized surface: the demos have to fit without overflowing.
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(home: Builder(builder: demo.builder)),
        );
        await settle(tester);

        expect(find.text(demo.title), findsWidgets);
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: '${demo.title} never finished opening its database',
        );
        expect(tester.takeException(), isNull);

        // Unmount the screen: controllers are disposed and the database closed.
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester, rounds: 50);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
