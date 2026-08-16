/// Thermion integration for assimp_dart.
///
/// Import this library to load Assimp-readable model files straight into a
/// Thermion viewer:
///
/// ```dart
/// import 'package:assimp_dart/thermion.dart';
///
/// final assets = await viewer.loadModel('model.obj');
/// ```
///
/// It adds `loadModel`/`loadModelFromBuffer` to [ThermionViewer] and
/// `toGeometry` to [RawMesh] (extensions), and re-exports this package's core
/// API so this one import is enough. The core library
/// (`package:assimp_dart/assimp_dart.dart`) stays free of thermion types:
/// import/export works without any rendering stack, and the headless tests
/// never touch thermion code.
library;

export 'package:assimp_dart/assimp_dart.dart';
export 'package:assimp_dart/src/thermion/src/assimp_viewer_extension.dart';
export 'package:assimp_dart/src/thermion/src/raw_mesh_geometry.dart';
