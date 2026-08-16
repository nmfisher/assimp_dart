/// Standalone Assimp-backed model-file import/export for Dart.
///
/// Parses model files (OBJ, FBX, glTF/glb, STL, PLY, ...) into flat meshes
/// ([RawMesh]) and writes them back out (FBX), with no rendering or
/// thermion_dart dependency. The native side is a single shared library
/// (libassimp_dart) built by hook/build.dart, which links the prebuilt
/// libassimp shipped in the Thermion R2 artifacts.
///
/// Extracted from thermion_dart's model_import facade (thermion PR #195).
library;

export 'src/model_import/model_import.dart';
