/// The food log for one day: meals and items, calories only where the user
/// stated them, and one total line. Opened only through ViewHost.
library;

import 'package:flutter/material.dart';

import '../log_entry.dart';
import '../log_math.dart';
import 'log_frame.dart';

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// `pieces` and `servings` past one; `g` and `ml` never change.
String? _unit(FoodItem i) {
  final u = i.unit;
  if (u == null) return null;
  final many = i.quantity != null && i.quantity != 1 && (u == 'piece' || u == 'serving');
  return many ? '${u}s' : u;
}

/// An item's amount and calories: `200 g · 260 kcal est.`. An estimate
/// always carries "est."; a stated figure never does.
String foodAmount(FoodItem i) {
  final qty = [if (i.quantity != null) numText(i.quantity!), ?_unit(i)].join(' ');
  return [if (qty.isNotEmpty) qty, if (i.kcal != null) '${numText(i.kcal!)} kcal${i.estimated ? ' est.' : ''}'].join(' · ');
}

List<Widget> foodRows(List<LogEntry> entries) => [
      for (final e in entries.whereType<FoodEntry>()) ...[
        if (e.meal != null) LogHeading(_cap(e.meal!)),
        for (final i in e.items) LogRow(i.name, foodAmount(i)),
      ],
    ];

String foodTotal(List<LogEntry> entries) {
  final t = foodTotals(entries.whereType<FoodEntry>());
  final items = '${t.items} item${t.items == 1 ? '' : 's'}';
  final all = entries.whereType<FoodEntry>().expand((e) => e.items);
  final estimated = all.where((i) => i.estimated);
  final est = estimated.length;
  final estKcal = estimated.fold<double>(0, (a, i) => a + (i.kcal ?? 0));
  final statedKcal = t.kcal - estKcal;
  if (t.stated == 0 && est == 0) return '$items · no calories stated';
  // Stated and estimated figures together: their sum first, then each part.
  final both = t.stated > 0 && est > 0 ? '${numText(t.kcal)} kcal in all' : '';
  final shown = t.stated == 0 ? '' : '${numText(statedKcal)} kcal stated for ${t.stated} of ${t.items}';
  return [items, if (both.isNotEmpty) both, if (shown.isNotEmpty) shown, if (est > 0) '$est estimated (${numText(estKcal)} kcal)']
      .join(' · ');
}

class FoodView extends StatelessWidget {
  const FoodView({super.key, required this.deps, required this.onClose});
  final LogViews deps;
  final VoidCallback onClose;

  /// One line; the field's hint shows the example, so it is not said twice.
  static const emptyText = 'Type what you ate below to log it.';

  @override
  Widget build(BuildContext context) => LogDayView(
        kind: LogKind.food,
        title: 'Food',
        deps: deps,
        onClose: onClose,
        rows: foodRows,
        total: foodTotal,
        emptyText: emptyText,
      );
}
