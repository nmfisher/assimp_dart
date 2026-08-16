import 'dart:typed_data';

import 'package:assimp_dart/src/model_import/src/raw_mesh.dart';

/// Parses a model-file byte buffer into a list of flat meshes ([RawMesh]).
///
/// The implementation behind this interface in this package:
///
/// - [AssimpImporter] — any format Assimp reads (OBJ, FBX, glTF/glb, STL,
///   PLY, ...). Always available: this package is unconditionally built with
///   Assimp linked in.
///
/// (thermion_dart's model_import facade also has a CgltfImporter backed by
/// the cgltf parser compiled into its Filament build; that path lives with
/// Filament and is out of scope for this standalone package.)
abstract interface class ModelFileImporter {
  /// Whether this importer is available in the current build.
  bool get isSupported;

  /// Parse [data] and return one [RawMesh] per mesh in the file.
  ///
  /// [formatHint] is the file extension without the dot (e.g. "obj", "fbx",
  /// "glb"). Assimp needs it to select the right importer when reading from
  /// memory.
  ///
  /// Throws on unparseable files.
  List<RawMesh> parse(Uint8List data, {required String formatHint});
}
