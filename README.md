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
  same vertical UV flip at upload time.

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
