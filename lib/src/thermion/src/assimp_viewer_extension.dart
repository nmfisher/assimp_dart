import 'package:assimp_dart/src/model_import/src/assimp_importer.dart';
import 'package:assimp_dart/src/thermion/src/raw_mesh_geometry.dart';
import 'package:thermion_dart/thermion_dart.dart';

/// Viewer-level Assimp model loading, owning the API thermion_dart's
/// `loadModel`/`loadModelFromBuffer` provided on its feat/assimp-integration
/// branch (thermion_dart/lib/src/viewer/src/ffi/src/thermion_viewer_ffi.dart).
///
/// Importing `package:assimp_dart/thermion.dart` puts these on any
/// [ThermionViewer], so call sites keep working unchanged:
///
/// ```dart
/// final assets = await viewer.loadModel('model.obj');            // List<ThermionAsset>
/// final assets2 = await viewer.loadModelFromBuffer(bytes, formatHint: 'fbx');
/// ```
///
/// This is the ASSIMP path — any format Assimp reads (OBJ/FBX/STL/PLY/
/// glTF...). It is not thermion's gltfio path (`loadGltf`) nor its cgltf
/// parser (`parseGltf`), both of which stay in thermion_dart.
///
/// ## `addToScene: false` caveat
///
/// With `addToScene: true` (default) each mesh goes through the viewer-level
/// `createGeometry`, which registers the asset with the viewer (so
/// `destroyAssets` covers it) and adds it to the scene. Thermion's develop
/// branch exposes no `addToScene` parameter on that method, so
/// `addToScene: false` creates through `viewer.app.createGeometry` instead:
/// the asset is NOT registered with the viewer and must be destroyed with
/// `destroyAsset`/`app.destroyAsset`. (On the feat branch both paths
/// registered; when thermion's interface gains the parameter, this can call
/// the viewer-level method unconditionally.)
extension AssimpModelLoader on ThermionViewer {
  /// Loads a model file over thermion's resource loader and creates one
  /// [ThermionAsset] per mesh in it.
  ///
  /// [uri] is passed to `FilamentApp.instance.loadResource`; the Assimp
  /// format hint is inferred from the URI's extension (see
  /// [extensionHintFromUri]).
  Future<List<ThermionAsset>> loadModel(
    String uri, {
    bool addToScene = true,
    bool flipUvs = true,
  }) async {
    final data = await FilamentApp.instance!.loadResource(uri);
    final formatHint = extensionHintFromUri(uri);
    return loadModelFromBuffer(
      data,
      formatHint: formatHint,
      addToScene: addToScene,
      flipUvs: flipUvs,
    );
  }

  /// Parses a model file from [data] with Assimp and creates one
  /// [ThermionAsset] per mesh.
  ///
  /// [formatHint] is the file extension without the dot (e.g. "obj", "fbx",
  /// "glb", "stl", "ply"); Assimp uses it to select the right importer when
  /// reading from memory.
  ///
  /// [flipUvs] flips UV coordinates vertically (default true): most formats
  /// (OBJ, FBX) use a bottom-left UV origin while Filament uses top-left.
  /// Flipping is applied at the Dart/Geometry boundary only, never in native
  /// Assimp, so it is never double-applied.
  ///
  /// The parsed [RawMesh]es are disposed in a `finally` block once every
  /// geometry has been uploaded: their native buffers back the typed-data
  /// views handed to `createGeometry`, which uploads (copies) synchronously
  /// before its future resolves.
  Future<List<ThermionAsset>> loadModelFromBuffer(
    Uint8List data, {
    required String formatHint,
    bool addToScene = true,
    bool flipUvs = true,
  }) async {
    final meshes = AssimpImporter().parse(data, formatHint: formatHint);
    final assets = <ThermionAsset>[];

    try {
      for (final mesh in meshes) {
        final geometry = mesh.toGeometry(
          flipUvs: flipUvs,
          createDummyColors: true,
          createDummyUvs: true,
        );
        // addToScene: the viewer-level call also registers the asset with
        // the viewer (see the caveat on the extension). Without it, create
        // through the app so nothing is added to the scene.
        final asset = addToScene
            ? await createGeometry(geometry)
            : await app.createGeometry(geometry);
        assets.add(asset);
      }
    } finally {
      // The geometries' positions/normals are views over native buffers
      // owned by their RawMesh. createGeometry's uploads copy the bytes
      // synchronously (the *RenderThread setters std::copy into a
      // std::vector before returning) and the awaited future resolves only
      // after the engine has taken them, so the buffers are no longer
      // needed once every upload has completed.
      for (final mesh in meshes) {
        mesh.dispose();
      }
    }

    return assets;
  }
}

/// Extracts the Assimp format hint (file extension without dot, lowercased)
/// from a URI/path. Returns "obj" if no extension is found.
///
/// Ported from thermion's `_extensionHintFromUri` (feat/assimp-integration);
/// top-level because extensions cannot declare static members.
String extensionHintFromUri(String uri) {
  final withoutQuery = uri.split('?').first.split('#').first;
  final dot = withoutQuery.lastIndexOf('.');
  if (dot < 0 || dot == withoutQuery.length - 1) return 'obj';
  final ext = withoutQuery.substring(dot + 1).toLowerCase();
  // Strip a trailing compressed extension like ".gz" (e.g. "file.glb.gz").
  if (ext == 'gz') {
    final inner = withoutQuery.substring(0, dot);
    final innerDot = inner.lastIndexOf('.');
    if (innerDot >= 0) {
      return inner.substring(innerDot + 1).toLowerCase();
    }
  }
  return ext;
}
