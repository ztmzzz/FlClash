import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:path/path.dart';

Future<Directory> ensureMitmDir() async {
  final home = await appPath.homeDirPath;
  final dir = Directory(join(home, 'mitm'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

Future<File> mitmFile(String name) async {
  final dir = await ensureMitmDir();
  return File(join(dir.path, name));
}
