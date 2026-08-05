import 'package:flutter/material.dart';

/// A single labelled measurement shown in a [StatsCard].
@immutable
class Stat {
  /// Creates a statistic.
  const Stat(this.label, this.value);

  /// Short name of the measurement.
  final String label;

  /// Formatted value.
  final String value;
}

/// A card showing a group of statistics read from the database.
class StatsCard extends StatelessWidget {
  /// Creates a statistics card.
  const StatsCard({super.key, required this.title, required this.stats});

  /// Heading of the group.
  final String title;

  /// The measurements to show.
  final List<Stat> stats;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: <Widget>[
                for (final Stat stat in stats)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        stat.value,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        stat.label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
