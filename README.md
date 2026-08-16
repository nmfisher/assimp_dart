# assimp_dart

[Assimp](https://github.com/assimp/assimp) model-file import and export for
Dart — plus an optional Thermion integration layer that loads model files
straight into a viewer.

Parses model files (OBJ, FBX, glTF/glb, STL, PLY, ...) into flat meshes
(`RawMesh`) and writes them back out (FBX). Extracted from the
[model_import facade in thermion_dart](https://github.com/nmfisher/thermion/tree/feat/assimp-integration/thermion_dart/lib/src/model_import)
(thermion PR #195). The core import/export API (`assimp_dart.dart`) has no
rendering dependency and runs headless; the thermion integration
(`thermion.dart`) is a compile-time-only `thermion_dart` dependency and owns
the viewer-level `loadModel`/`loadModelFromBuffer` API.

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

## Thermion integration

`import 'package:assimp_dart/thermion.dart';` adds Assimp model loading to
any `ThermionViewer` (extensions), so call sites keep the shape thermion's
in-tree implementation had:

```dart
import 'package:assimp_dart/thermion.dart';

// One ThermionAsset per mesh in the file; added to the scene by default.
final assets = await viewer.loadModel('model.obj');
final assets2 = await viewer.loadModelFromBuffer(bytes, formatHint: 'fbx');
```

- `loadModel(uri, {addToScene = true, flipUvs = true})` loads the bytes over
  `FilamentApp.instance.loadResource` and infers the format hint from the
  URI's extension.
- `loadModelFromBuffer(data, {required formatHint, addToScene = true,
  flipUvs = true})` parses with `AssimpImporter`, converts each `RawMesh`
  with `toGeometry` (also an extension, on `RawMesh`), and creates one
  `ThermionAsset` per mesh. The meshes are disposed in a `finally` block
  once every geometry upload has completed.
- This is the Assimp path only. Thermion's gltfio path (`loadGltf`) and its
  cgltf parser (`parseGltf`) stay in thermion_dart.
- With `addToScene: false`, assets are created through
  `viewer.app.createGeometry`: thermion's develop branch has no `addToScene`
  parameter on the viewer-level `createGeometry`, so such assets are not
  registered with the viewer — destroy them with `destroyAsset` rather than
  relying on `destroyAssets`.

`thermion_dart` is pinned to a specific commit of the thermion repository
(see `pubspec.yaml`); when thermion's API moves, bump the ref deliberately.
When this package is the root (`dart test` / `dart run` here),
`hooks.user_defines.thermion_dart.skip_native_build: true` keeps the
headless tests free of any Filament native build; a downstream app is the
root and controls that define itself.

## Build

`dart pub get` / `dart test` / `dart run` trigger the build hook
(`hook/build.dart`), which:

1. downloads the prebuilt Filament artifact zip for the target platform from
   Cloudflare R2 (`https://pub-c8b6266320924116aaddce03b5313c0a.r2.dev`,
   pinned by `filament.version`) and extracts from it only `libassimp.a`
   (`assimp.lib` on Windows), `z.lib` (Windows) and the assimp headers under
   `include/third_party/libassimp/include/`;
2. compiles `native/src/c_api/` (model import + export + the shared
   `TMeshData` transfer struct) and links everything into a single
   `libassimp_dart.so` / `assimp_dart.dll` code asset.

The package is **always** Assimp-enabled — there is no compile-time switch
and no `user_defines.assimp`. The only user-define is `mode: debug` (default
`release`), which selects the debug variant of the R2 artifact:

```yaml
# consuming package's pubspec.yaml
hooks:
  user_defines:
    assimp_dart:
      mode: debug
```

### C++ ABI note (Linux)

Everything linked into `libassimp_dart.so` must come from one C++ runtime.
The R2 `libassimp.a` is a **libc++** build, so the hook compiles with
`-stdlib=libc++` and fails the build (`_assertSingleCppAbi`) if the artifact
ever regresses to a libstdc++ build — linking both runtimes into one process
crashes inside libc++abi's exception/RTTI machinery (the Linux x64 FBX
round-trip crash seen in thermion's CI, PR #195). CI installs clang-18 +
libc++-18 from apt.llvm.org, matching the artifact builder.

## Scope vs thermion_dart

- `AssimpImporter` / `AssimpExporter` / `RawMesh` /
  `ModelFileImporter` / `ModelFileExporter` are ported as-is.
- `RawMesh.toGeometry` (conversion to thermion's render-side `Geometry`
  type) is available as an extension in `package:assimp_dart/thermion.dart`;
  `RawMesh.flipUVs` stays on the core type for upload-time flips.
- `CgltfImporter` (glTF via cgltf) is **not** ported: it parses through the
  cgltf code compiled into thermion's Filament build, which this package
  does not link.

## Tests

```sh
dart test test/model_import_tests.dart test/model_export_tests.dart
```

Pure parse/export tests — no Filament, no GPU, no xvfb. Includes the FBX
round-trip test (export → re-import preserves mesh data and names) and the
garbage-bytes regression test (malformed input for fbx/obj/stl/ply must
throw, not crash the process).

The thermion integration has no test in this repository: it needs a live
Filament viewer/engine. CI still type-checks it (`dart analyze`) against the
pinned thermion commit; runtime coverage comes from thermion's own examples
and tests once thermion delegates here.

`tool/stress_concurrent_import.dart` hammers the importer/exporter from
several isolates concurrently — the reproduction for a heap-corruption race
through Assimp's process-global `DefaultLogger` (fixed here by not touching
the global logger; see `native/src/c_api/model_import.cpp`).

## Status

Linux (x64, arm64) and Windows x64 are exercised in CI. The prebuilt
artifacts also exist for macOS; Android/iOS are not wired up yet.

## License

Apache 2.0 (as thermion).
