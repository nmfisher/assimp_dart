import 'dart:io';
import 'dart:typed_data';

import 'package:assimp_dart/assimp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ported from thermion_dart/test/model_import_tests.dart.
///
/// Differences from the thermion version, all forced by the standalone split
/// (this package links libassimp only — no Filament, no viewer, no
/// thermion_dart types):
///
///  - The OBJ tests go through [AssimpImporter] (formatHint 'obj') instead of
///    GeometryUtils.parseObjFromBuffer, thermion's pure-Dart OBJ parser whose
///    Geometry/GeometryGroup result types are render-side thermion types. The
///    same fixtures (test_cube.obj plus the inline OBJ snippets) and the same
///    assertions are kept.
///  - The two UV-flip tests exercise [RawMesh.flipUVs] — the identical flip
///    routine thermion applies inside RawMesh.toGeometry at upload time
///    (v = 1 - v, u unchanged) — since there is no geometry-upload step here.
///  - thermion's 'load OBJ and create renderable asset' test is not portable
///    headless (it needs ViewerBuilder + a Filament rendering surface); it
///    stays in the thermion repo.
void main() async {
  final assetsDir = p.join(Directory.current.path, 'test', 'assets');

  group('OBJ Loading', () {
    test('load OBJ file from buffer and parse geometry', () async {
      final objPath = p.join(assetsDir, "test_cube.obj");
      final buffer = File(objPath).readAsBytesSync();

      // Parse OBJ file
      final meshes = AssimpImporter().parse(buffer, formatHint: 'obj');

      // Should have at least one mesh group
      expect(meshes.isNotEmpty, true, reason: "OBJ file should contain at least one mesh group");

      final mesh = meshes.first;
      try {
        // Verify vertices
        expect(mesh.positions.isNotEmpty, true, reason: "Mesh should have vertices");
        expect(mesh.positions.length % 3, 0, reason: "Vertices should be in groups of 3 (x,y,z)");

        // Verify indices
        expect(mesh.indices.isNotEmpty, true, reason: "Mesh should have indices");
        expect(mesh.indices.length % 3, 0, reason: "Indices should be in groups of 3 (triangles)");

        print("Parsed OBJ with ${mesh.positions.length ~/ 3} vertices");
        print("Parsed ${mesh.indices.length ~/ 3} triangles");
        print("Has normals: ${mesh.normals.isNotEmpty}");
        print("Has UVs: ${mesh.uvs.isNotEmpty}");

        // Cube should have 8 vertices and 12 triangles (4 per face * 6 faces / 2 for quads)
        // But OBJ can have more vertices due to attribute splitting
        final vertexCount = mesh.positions.length ~/ 3;
        final triangleCount = mesh.indices.length ~/ 3;

        expect(vertexCount, greaterThan(0));
        expect(triangleCount, greaterThan(0));
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    test('load OBJ with UV flipping disabled', () async {
      final objPath = p.join(assetsDir, "test_cube.obj");
      final buffer = File(objPath).readAsBytesSync();

      // Parse without UV flipping (the import path never flips)
      final meshes = AssimpImporter().parse(buffer, formatHint: 'obj');

      expect(meshes.isNotEmpty, true);
      try {
        expect(meshes.first.uvs.isNotEmpty, true);

        // Verify UVs are in original orientation
        final uvs = meshes.first.uvs;
        expect(uvs.isNotEmpty, true);
        expect(uvs.length % 2, 0, reason: "UVs should be in pairs (u,v)");
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    test('load OBJ with UV flipping enabled', () async {
      final objPath = p.join(assetsDir, "test_cube.obj");
      final buffer = File(objPath).readAsBytesSync();

      final meshes = AssimpImporter().parse(buffer, formatHint: 'obj');

      expect(meshes.isNotEmpty, true);
      try {
        expect(meshes.first.uvs.isNotEmpty, true);

        // Verify UVs are flipped (v = 1.0 - v, u unchanged)
        final original = meshes.first.uvs;
        final uvs = RawMesh.flipUVs(original);
        expect(uvs.isNotEmpty, true);
        expect(uvs.length % 2, 0, reason: "UVs should be in pairs (u,v)");

        // Check that V values are flipped (1.0 - v)
        // Original OBJ has v values 0.0 or 1.0, so flipped should be 1.0 or 0.0
        for (int i = 1; i < uvs.length; i += 2) {
          final v = uvs[i];
          expect(v, greaterThanOrEqualTo(0.0), reason: "Flipped V value should be >= 0");
          expect(v, lessThanOrEqualTo(1.0), reason: "Flipped V value should be <= 1");
        }
        // u passes through untouched
        for (int i = 0; i < uvs.length; i += 2) {
          expect(uvs[i], original[i], reason: "Flip must not change u values");
        }
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    test('handle OBJ file with no normals or UVs', () async {
      // Create a minimal OBJ with just vertices (use triangles)
      final minimalObj = '''
# Minimal OBJ - positions only
v 0.0 0.0 0.0
v 1.0 0.0 0.0
v 1.0 1.0 0.0
v 0.0 1.0 0.0
f 1 2 3
f 1 3 4
''';
      final buffer = Uint8List.fromList(minimalObj.codeUnits);

      final meshes = AssimpImporter().parse(buffer, formatHint: 'obj');

      print("Meshes count: ${meshes.length}");
      if (meshes.isNotEmpty) {
        print("First mesh has ${meshes.first.positions.length ~/ 3} vertices");
        print("First mesh has normals: ${meshes.first.normals.isNotEmpty}");
        print("First mesh has UVs: ${meshes.first.uvs.isNotEmpty}");
      }
      try {
        expect(meshes.isNotEmpty, true);
        final mesh = meshes.first;

        // Should have vertices
        expect(mesh.positions.isNotEmpty, true);

        // The import applies aiProcess_GenNormals, so normals exist even for
        // a positions-only file (thermion's Geometry constructor instead
        // created dummy UVs/colors at upload time — a render-side concern).
        expect(mesh.normals.isNotEmpty, true, reason: "GenNormals should supply normals");
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    test('handle OBJ file with multiple groups', () async {
      // Create OBJ with multiple objects
      final multiGroupObj = '''
# First cube
o Cube1
v -1.0 -1.0 1.0
v 1.0 -1.0 1.0
v 1.0 1.0 1.0
v -1.0 1.0 1.0
f 1 2 3 4

# Second cube
o Cube2
v 2.0 0.0 0.0
v 3.0 0.0 0.0
v 3.0 1.0 0.0
v 2.0 1.0 0.0
f 5 6 7 8
''';
      final buffer = Uint8List.fromList(multiGroupObj.codeUnits);

      final meshes = AssimpImporter().parse(buffer, formatHint: 'obj');

      try {
        // Should have two groups (one for each 'o' directive)
        expect(meshes.length, greaterThanOrEqualTo(1));

        // Total vertices should be 8 (4 per cube)
        final totalVertices = meshes.fold<int>(0, (sum, m) => sum + m.positions.length ~/ 3);
        expect(totalVertices, 8, reason: "Should have 8 vertices total (2 cubes × 4 vertices)");
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    test('verify mesh names and material names are preserved', () async {
      final objWithNames = '''
# OBJ with names and materials
o TestMesh
usemtl TestMaterial
v -0.5 -0.5 0.5
v 0.5 -0.5 0.5
v 0.5 0.5 0.5
v -0.5 0.5 0.5
f 1 2 3
f 1 3 4
''';
      final buffer = Uint8List.fromList(objWithNames.codeUnits);

      final meshes = AssimpImporter().parse(buffer, formatHint: 'obj');

      expect(meshes.isNotEmpty, true);
      try {
        final mesh = meshes.first;

        // Should have mesh name
        expect(mesh.name, isNotNull);
        expect(mesh.name, contains("TestMesh"));

        // Should have material name
        expect(mesh.materialName, isNotNull);
        expect(mesh.materialName, contains("TestMaterial"));
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });
  });

  // Exercises the unified model-import facade (AssimpImporter → RawMesh).
  // Assimp selects the importer from the format hint rather than the
  // hardcoded "obj" path, using text-based formats we can author inline.
  // This is the regression test for "FBX/multi-format" support: any
  // Assimp-readable format works once the correct hint is supplied.
  group('Multi-format loading (ModelFileImporter facade)', () {
    test('load STL via formatHint and parse geometry', () async {
      // Minimal ASCII STL: two triangles forming a quad in the XY plane.
      final stl = '''
solid test
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 1 0 0
      vertex 1 1 0
    endloop
  endfacet
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 1 1 0
      vertex 0 1 0
    endloop
  endfacet
endsolid test
''';
      final buffer = Uint8List.fromList(stl.codeUnits);

      expect(AssimpImporter().isSupported, true, reason: "Tests require a build with Assimp enabled");

      final meshes = AssimpImporter().parse(buffer, formatHint: 'stl');

      try {
        expect(meshes.isNotEmpty, true, reason: "STL should parse into at least one mesh");
        final mesh = meshes.first;
        expect(mesh.positions.isNotEmpty, true);
        expect(mesh.positions.length % 3, 0, reason: "Positions should be in groups of 3 (x,y,z)");
        // Two triangles -> 6 indices.
        expect(mesh.indices.length, 6, reason: "STL quad (2 triangles) should have 6 indices");
        expect(mesh.primitiveType, PrimitiveType.TRIANGLES);
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    test('load PLY via formatHint and parse geometry', () async {
      // Minimal ASCII PLY: a single triangle.
      final ply = '''
ply
format ascii 1.0
element vertex 3
property float x
property float y
property float z
element face 1
property list uchar int vertex_indices
end_header
0 0 0
1 0 0
0 1 0
3 0 1 2
''';
      final buffer = Uint8List.fromList(ply.codeUnits);

      final meshes = AssimpImporter().parse(buffer, formatHint: 'ply');

      try {
        expect(meshes.isNotEmpty, true, reason: "PLY should parse into at least one mesh");
        expect(meshes.first.indices.length, 3, reason: "PLY single triangle should have 3 indices");
      } finally {
        for (final m in meshes) {
          m.dispose();
        }
      }
    });

    // Regression: malformed data fed to an importer must surface as a Dart
    // exception. The native entry points catch C++ exceptions at the FFI
    // boundary; without that barrier an exception escaping Assimp unwinds
    // through Dart frames and kills the process (CI crashed this way inside
    // libc++abi on Linux x64).
    test('garbage data throws instead of crashing (per format)', () {
      final importer = AssimpImporter();
      // Pseudo-random non-zero bytes: enough structure to draw the binary
      // FBX/STL readers deep into parsing before they reject it.
      final garbage = Uint8List.fromList(List<int>.generate(1024, (i) => (i * 31 + 7) & 0xFF));
      for (final hint in ['fbx', 'obj', 'stl', 'ply']) {
        expect(
          () => importer.parse(garbage, formatHint: hint),
          throwsException,
          reason: "Garbage input with hint '$hint' should throw, not crash",
        );
      }
    });
  });
}
