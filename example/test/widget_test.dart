// Widget tests for the ReaxDB example.
//
// These cover the parts of the app that do not touch the file system. The
// database code the demos are built from is exercised in
// `database_service_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:reaxdb_example/main.dart';
import 'package:reaxdb_example/widgets/console_widget.dart';
import 'package:reaxdb_example/widgets/demo_scaffold.dart';
import 'package:reaxdb_example/widgets/stats_card.dart';

void main() {
  group('catalogue', () {
    testWidgets('lists the demos', (WidgetTester tester) async {
      await tester.pumpWidget(const ReaxDBExampleApp());
      await tester.pump();

      expect(find.text('ReaxDB Example'), findsOneWidget);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Typed collections'), findsOneWidget);
      expect(find.byType(ListTile), findsWidgets);
    });

    testWidgets('every demo has a summary and an API line', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const ReaxDBExampleApp());
      await tester.pump();

      for (final Demo demo in demos) {
        expect(demo.summary, isNotEmpty, reason: demo.title);
        expect(demo.api, isNotEmpty, reason: demo.title);
      }
      expect(demos, hasLength(10));
    });

    testWidgets('scrolls to the last demo', (WidgetTester tester) async {
      await tester.pumpWidget(const ReaxDBExampleApp());
      await tester.pump();

      await tester.dragUntilVisible(
        find.text('Chat'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Chat'), findsOneWidget);
    });
  });

  group('ConsoleController', () {
    test('appends lines with a tone and clears them', () {
      final ConsoleController controller = ConsoleController();
      addTearDown(controller.dispose);

      controller.info('one');
      controller.success('two');
      controller.failure('three');

      expect(controller.value, hasLength(3));
      expect(controller.value.last.tone, LogTone.failure);

      controller.clear();
      expect(controller.value, isEmpty);
    });

    test('section separates groups with a blank line', () {
      final ConsoleController controller = ConsoleController();
      addTearDown(controller.dispose);

      controller.section('first');
      expect(controller.value, hasLength(1));

      controller.section('second');
      expect(controller.value, hasLength(3));
      expect(controller.value[1].text, isEmpty);
    });
  });

  group('shared widgets', () {
    testWidgets('ConsoleWidget renders lines and clears on demand', (
      WidgetTester tester,
    ) async {
      final ConsoleController controller = ConsoleController();
      addTearDown(controller.dispose);
      controller.success('write acknowledged');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConsoleWidget(controller: controller)),
        ),
      );

      expect(find.textContaining('write acknowledged'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear output'));
      await tester.pump();

      expect(find.textContaining('write acknowledged'), findsNothing);
      expect(find.text('Run an action to see output here.'), findsOneWidget);
    });

    testWidgets('StatsCard shows every statistic', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatsCard(
              title: 'Cache',
              stats: <Stat>[Stat('Hits', '12'), Stat('Misses', '3')],
            ),
          ),
        ),
      );

      expect(find.text('Cache'), findsOneWidget);
      expect(find.text('Hits'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('ErrorCard names the typed exception', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ErrorCard(
              error: DatabaseLockedException('already open', path: '/tmp/db'),
            ),
          ),
        ),
      );

      expect(find.text('DatabaseLockedException'), findsOneWidget);
      expect(find.text('already open'), findsOneWidget);
    });

    testWidgets('DemoScaffold shows the description and the snippet', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DemoScaffold(
            title: 'Iteration',
            description: 'Ordered iteration over the key space.',
            snippet: "await db.scanPrefix('city:');",
            child: SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Iteration'), findsOneWidget);
      expect(
        find.text('Ordered iteration over the key space.'),
        findsOneWidget,
      );
      expect(find.text("await db.scanPrefix('city:');"), findsOneWidget);
    });
  });
}
