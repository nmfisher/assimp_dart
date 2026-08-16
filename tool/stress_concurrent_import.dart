// Stress tool: hammers the importer/exporter from several isolates at once.
//
// Exists to reproduce the heap corruption seen when test files ran with
// default concurrency (two isolates importing concurrently → glibc
// "corrupted size vs. prev_size"). Assimp::DefaultLogger::create/kill used
// to be called on every import and mutates process-global state, so
// concurrent imports raced on it; the import path no longer touches the
// global logger (see native/src/c_api/model_import.cpp).
//
// Run with: dart run tool/stress_concurrent_import.dart [isolates] [iters]
import 'dart:isolate';
import 'dart:typed_data';

import 'package:assimp_dart/assimp_dart.dart';

const obj = '''
o TestMesh
usemtl TestMaterial
v -1 0 1
v 1 0 1
v 1 0 -1
v -1 0 -1
vn 0 1 0
vn 0 1 0
vn 0 1 0
vn 0 1 0
vt 0 1
vt 1 1
vt 1 0
vt 0 0
f 1/1/1 2/2/2 3/3/3
f 1/1/1 3/3/3 4/4/4
''';

Future<void> worker(int iters) async {
  final buffer = Uint8List.fromList(obj.codeUnits);
  final importer = AssimpImporter();
  final exporter = AssimpExporter();
  for (var i = 0; i < iters; i++) {
    // Import + export round trip plus a garbage read.
    final meshes = importer.parse(buffer, formatHint: 'obj');
    try {
      final fbx = exporter.export(meshes, formatHint: 'fbx');
      final back = importer.parse(fbx, formatHint: 'fbx');
      if (back.length != meshes.length) {
        throw StateError('round trip changed mesh count');
      }
      for (final mesh in back) {
        mesh.dispose();
      }
    } finally {
      for (final mesh in meshes) {
        mesh.dispose();
      }
    }
    try {
      importer.parse(Uint8List.sublistView(buffer, 0, 64), formatHint: 'ply');
    } on Exception {
      // expected
    }
  }
}

void main(List<String> args) async {
  final isolateCount = int.tryParse(args.isNotEmpty ? args[0] : '') ?? 8;
  final iters = int.tryParse(args.length > 1 ? args[1] : '') ?? 200;
  print('stress: $isolateCount isolates × $iters iterations of parse+export');

  final watchers = <Future<void>>[];
  for (var i = 0; i < isolateCount; i++) {
    watchers.add(Isolate.run(() => worker(iters)));
  }
  await Future.wait(watchers);
  print('stress: OK — no heap corruption, all round trips intact');
}
