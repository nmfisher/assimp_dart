import 'package:assimp_dart/src/bindings/assimp_dart_ffi.dart';
import 'package:assimp_dart/src/model_import/src/model_file_importer.dart';
import 'package:assimp_dart/src/model_import/src/raw_mesh.dart';

/// The `allocate` shim (see the bindings) hands out pointer-sized slots and
/// only supports Char/Pointer elements. TMeshData spans several slots, so
/// request the ceiling in pointer units and cast.
final int _tMeshDataSlots = (sizeOf<TMeshData>() + sizeOf<Pointer>() - 1) ~/ sizeOf<Pointer>();

/// [ModelFileImporter] backed by the Assimp native library.
///
/// Supports any format Assimp can read (OBJ, FBX, glTF/glb, STL, PLY, ...).
/// Mesh vertices/normals are already transformed into world space by the
/// native layer (accumulated `aiScene` node transforms), so multi-node
/// scenes come out correctly.
///
/// This package always compiles and links Assimp in (no opt-in), so
/// [isSupported] is always true.
class AssimpImporter implements ModelFileImporter {
  @override
  bool get isSupported => ModelImporter_isSupported();

  @override
  List<RawMesh> parse(Uint8List data, {required String formatHint}) {
    final dataPointer = allocate<Char>(data.length).cast<Uint8>();
    dataPointer.asTypedList(data.length).setAll(0, data);

    // Assimp's format hint: file extension without the leading dot.
    final hintPointer = formatHint.toNativeUtf8().cast<Char>();

    try {
      final importerPtr = ModelImporter_loadFromBuffer(dataPointer, data.length, hintPointer);

      if (importerPtr == nullptr) {
        throw Exception('Failed to load model ($formatHint): Assimp returned null importer');
      }

      try {
        final meshCount = ModelImporter_getMeshCount(importerPtr);
        if (meshCount == 0) {
          throw Exception('Failed to load model ($formatHint): No meshes found in file');
        }

        // Each mesh gets its own TMeshData: getMesh fills it with freshly
        // malloc'd buffers that are private copies of the scene data, and
        // ownership of struct + buffers moves into the RawMesh (freed by
        // RawMesh.dispose). Nothing is disposed between meshes — the views
        // handed to the caller stay valid after the importer is destroyed.
        final meshes = <RawMesh>[];

        try {
          for (int i = 0; i < meshCount; i++) {
            final outMesh = allocate<PointerClass>(_tMeshDataSlots).cast<TMeshData>();
            final result = ModelImporter_getMesh(importerPtr, i, outMesh);
            if (result != 0) {
              // getMesh may have filled the struct partially (it cleans up
              // its own buffers on malloc failure, but not the struct).
              MeshData_dispose(outMesh);
              free(outMesh);
              throw Exception('Failed to read mesh $i from model ($formatHint): error $result');
            }
            meshes.add(RawMesh.fromNative(outMesh));
          }
        } catch (_) {
          // Don't leak the meshes already adopted on the error path.
          for (final mesh in meshes) {
            mesh.dispose();
          }
          rethrow;
        }

        return meshes;
      } finally {
        ModelImporter_destroy(importerPtr);
      }
    } finally {
      free(dataPointer);
      free(hintPointer);
    }
  }
}
