// The guard's alias groups, built from the app's own bundled catalogs, equal the Python reference's groups.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:natural_farming_chat/services/guard_aliases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the groups built from the bundled assets equal the committed Python groups', () async {
    final expected = (jsonDecode(File('test/fixtures/guard_alias_groups.json').readAsStringSync()) as Map).map(
      (k, v) => MapEntry(k as String, [for (final g in v as List) [for (final a in g as List) a as String]]),
    );
    final built = await loadGuardAliasGroups();
    expect(built.keys.toSet(), expected.keys.toSet());
    for (final catalog in expected.keys) {
      expect(built[catalog], expected[catalog], reason: catalog);
    }
  });

  test('blank names are left out and rows with no name are skipped', () {
    final groups = aliasGroupsFromRows(
      [
        {'Crop': 'A', 'Scientific Name': ' '},
        {'Crop': '', 'Scientific Name': ''},
      ],
      [
        {'common_name': 'B', 'scientific_name': 'C'},
        <String, dynamic>{},
      ],
    );
    expect(groups['crop'], [['A']]);
    expect(groups['plant'], [['B', 'C']]);
  });
}
