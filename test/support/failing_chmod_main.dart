import 'dart:io';

import 'package:dox_storage/dox_storage.dart';

/// Run by a test with a `PATH` where `chmod` always fails.
/// Writes new files with `permissions` on, then prints `clean` when no
/// file is left in the root folder [args] `[0]`.
Future<void> main(List<String> args) async {
  Directory root = Directory(args[0]);
  for (bool atomic in <bool>[false, true]) {
    Disk disk = Disk(
      LocalDriver(
        LocalDriverConfig(
          root: root.path,
          atomicWrites: atomic,
          permissions: const LocalPermissions(),
        ),
      ),
    );
    try {
      await disk.put('a.txt', 'a');
      stdout.writeln('put did not throw');
    } on PermissionDeniedException {
      // expected
    }
    try {
      await disk.putStream('b.txt', Stream<List<int>>.value(<int>[1]));
      stdout.writeln('putStream did not throw');
    } on PermissionDeniedException {
      // expected
    }
  }
  List<FileSystemEntity> left = root.listSync();
  stdout.writeln(left.isEmpty ? 'clean' : 'left: $left');
}
