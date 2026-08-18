# assimp_dart

Standalone [Assimp](https://github.com/assimp/assimp) model-file import and
export for Dart — no rendering stack, no `thermion_dart` dependency.

Parses model files (OBJ, FBX, glTF/glb, STL, PLY, ...) into flat meshes
(`RawMesh`) and writes them back out (FBX). Extracted from the
[model_import facade in thermion_dart](https://github.com/nmfisher/thermion/tree/feat/assimp-integration/thermion_dart/lib/src/model_import)
(thermion PR #195).

## Usage

```dart
import 'dart:io';
import 'package:assimp_dart/assimp_dart.dart';

void main() {
  final bytes = File('model.obj').readAsBytesSync();

  // Import: any format Assimp reads. formatHint is the file extension
  // without the dot; it selects Assimp's importer when parsing from memory.
  final meshes = AssimpImporter().parse(bytes, formatHint: 'obj');
  for (final mesh in meshes) {
    print('${mesh.name}: ${mesh.vertexCount} vertices, '
          '${mesh.indices.length ~/ 3} triangles');
  }

  // Export the same meshes to binary FBX (also supports 'fbxa' for ASCII).
  final fbx = AssimpExporter().export(meshes, formatHint: 'fbx');
  File('model.fbx').writeAsBytesSync(fbx);

  for (final mesh in meshes) {
    mesh.dispose(); // frees the native buffers behind the typed-data views
  }
}
```

Ownership is explicit everywhere (thermion's convention): every native
allocation has a matching `dispose`/`destroy` call and there is no
`NativeFinalizer`. Mesh buffers produced by the importer are private native
copies — they stay valid after the importer is destroyed, until `dispose`.

## Build

`dart pub get` / `dart test` / `dart run` trigger the build hook
(`hook/build.dart`), which:

1. downloads the prebuilt libassimp artifact zip for the target platform
   from this repository's GitHub Releases (release tagged
   `libassimp-<filament.version>`, built and published by the "Build
   libassimp" workflow) and extracts from it `libassimp.a`
   (`assimp.lib` + `z.lib` on Windows) and the assimp headers under
   `include/third_party/libassimp/include/`;
2. compiles `native/src/c_api/` (model import + export + the shared
   `TMeshData` transfer struct) and links everything into a single
   `libassimp_dart.so` / `assimp_dart.dll` code asset.

The package is **always** Assimp-enabled — there is no compile-time switch
and no `user_defines.assimp`. The only user-define is `mode: debug` (default
`release`), which selects the debug variant of the release artifact:

```yaml
# consuming package's pubspec.yaml
hooks:
  user_defines:
    assimp_dart:
      mode: debug
```

### C++ ABI note (Linux)

Everything linked into `libassimp_dart.so` must come from one C++ runtime.
The published `libassimp.a` is a **libc++** build, so the hook compiles with
`-stdlib=libc++` and fails the build (`_assertSingleCppAbi`) if the artifact
ever regresses to a libstdc++ build — linking both runtimes into one process
crashes inside libc++abi's exception/RTTI machinery (the Linux x64 FBX
round-trip crash seen in thermion's CI, PR #195). CI installs clang-18 +
libc++-18 from apt.llvm.org, matching the artifact builder.

## Scope vs thermion_dart

- `AssimpImporter` / `AssimpExporter` / `RawMesh` /
  `ModelFileImporter` / `ModelFileExporter` are ported as-is.
- `CgltfImporter` (glTF via cgltf) is **not** ported: it parses through the
  cgltf code compiled into thermion's Filament build, which this package
  does not link.
- `RawMesh.toGeometry` (conversion to thermion's render-side `Geometry`
  type) is not ported; `RawMesh.flipUVs` is kept so consumers can apply the
  same vertical UV flip at upload time (see [Using with thermion](#using-with-thermion)).

## Using with thermion

Neither package depends on the other: assimp_dart parses, the render
package renders. The glue lives in the consumer, which reads `RawMesh`'s
plain typed lists and builds its own geometry:

```dart
import 'package:assimp_dart/assimp_dart.dart';

final meshes = AssimpImporter().parse(bytes, formatHint: 'obj');
final renderables = <Object>[];

try {
  for (final mesh in meshes) {
    // 1. Read the typed-data views (valid until dispose; see the contract).
    final positions = mesh.positions; // Float32List, 3 floats per vertex
    final normals = mesh.normals;     // Float32List, 3 per vertex; empty if absent
    var uvs = mesh.uvs;               // Float32List, 2 per vertex; empty if absent
    final indices = mesh.indices;     // Uint32List; empty if non-indexed

    // 2. Adapt to what the render package expects, e.g.:
    //    - UV origin: file formats mostly use bottom-left, GL-style
    //      renderers top-left. Flip on the Dart side only — native import
    //      never flips, so it is never double-applied:
    if (uvs.isNotEmpty) {
      uvs = RawMesh.flipUVs(uvs);
    }
    //    - Index width: narrow to 16-bit yourself if the renderer wants it
    //      (Uint16 is safe when mesh.vertexCount <= 65536).
    //    - Missing attributes: normals/uvs are empty when the file has
    //      none; fill dummy values if the material requires them.

    // 3. Build the render package's geometry from the lists and upload.
    //    Pseudocode — your renderer's API:
    //    final geometry = renderer.createGeometry(
    //        positions, indices, normals: normals, uvs: uvs);
    //    renderables.add(
    //        await renderer.createRenderable(geometry, name: mesh.name));
  }
} finally {
  // 4. Dispose exactly once, after every upload has completed.
  for (final mesh in meshes) {
    mesh.dispose();
  }
}
```

The dispose contract:

- `positions`/`normals`/`uvs`/`indices` are typed-data **views** over native
  memory owned by the `RawMesh`. They stay valid until `dispose()` — even
  after the importer itself is destroyed.
- Dispose once every consumer of the buffers is done. An upload that copies
  the bytes synchronously is finished when its call/future returns. If a
  renderer keeps the lists asynchronously without copying, make your own
  copy first (`Float32List.fromList(mesh.positions)`).
- `dispose()` is idempotent, but after it returns the views point to freed
  memory and must not be read. A mesh that is never disposed holds its
  native memory until process exit — there is no finalizer.
- Meshes built through the public `RawMesh(...)` constructor own plain Dart
  lists and need no disposal.

For thermion specifically: hand the lists to thermion's `Geometry` +
`createGeometry`. The conversion thermion's in-tree `RawMesh.toGeometry`
used to perform — UV flip, dummy colors/UVs, USHORT index narrowing — is
exactly this consumer-side step. glTF loading stays on thermion's own
gltfio path (`loadGltf`); assimp_dart is for the other formats.

## Tests

```sh
dart test test/model_import_tests.dart test/model_export_tests.dart
```

Pure parse/export tests — no Filament, no GPU, no xvfb. Includes the FBX
round-trip test (export → re-import preserves mesh data and names) and the
garbage-bytes regression test (malformed input for fbx/obj/stl/ply must
throw, not crash the process).

`tool/stress_concurrent_import.dart` hammers the importer/exporter from
several isolates concurrently — the reproduction for a heap-corruption race
through Assimp's process-global `DefaultLogger` (fixed here by not touching
the global logger; see `native/src/c_api/model_import.cpp`).

## Status

Linux (x64, arm64) and Windows x64 are exercised in CI. The prebuilt
artifacts also exist for macOS; Android/iOS are not wired up yet.

## License

Apache 2.0 (as thermion).
