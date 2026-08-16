/// FFI bindings for the model import/export C API in libassimp_dart
/// (native/src/c_api/).
///
/// Hand-written against native/include/c_api/{TMeshData,model_import,
/// model_export}.h — the same declarations thermion_dart generates with
/// ffigen (thermion_dart/lib/src/bindings/src/thermion_dart_ffi.g.dart) —
/// trimmed to the symbols this package's library exports. Keeping them
/// hand-written avoids an ffigen+libclang dev dependency for consumers;
/// regenerate-by-hand if the headers change.
///
/// Conventions carried over from thermion_dart (see its bindings/src/ffi.dart):
///
///  - Memory crossing the boundary goes through the [allocate]/[free] shim
///    below, never through raw malloc in caller code.
///  - Ownership is explicit: every native allocation has a matching dispose
///    call ([MeshData_dispose] for mesh buffers, [ModelImporter_destroy] for
///    importer handles, [ModelExporter_disposeBuffer] for export buffers).
///    There is no NativeFinalizer anywhere.
@DefaultAsset('package:assimp_dart/assimp_dart.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// Re-export the FFI surface the importers/exporters build on (thermion's
// bindings/src/ffi.dart exposes the same surface): the full dart:ffi +
// package:ffi namespaces, so the asTypedList/toNativeUtf8/toDartString
// extensions resolve for consumers too. Size stays hidden — nothing outside
// the @Native signatures below needs it.
export 'dart:typed_data';
export 'dart:ffi' hide Size;
export 'package:ffi/ffi.dart';

/// Slot-shaped pointer alias used with the [allocate] shim (thermion's
/// bindings/src/ffi.dart defines the same typedef).
typedef PointerClass<T extends NativeType> = Pointer<T>;

/// The `allocate` shim (thermion's bindings/src/ffi.dart has the identical
/// helper): hands out zeroed, pointer-sized slots and only supports
/// Char/Pointer elements. TMeshData spans several slots, so request the
/// ceiling in pointer units and cast.
Pointer<T> allocate<T extends NativeType>(int count) {
  return calloc.allocate<T>(count * sizeOf<Pointer>());
}

void free(Pointer ptr) {
  calloc.free(ptr);
}

/// Opaque handle to a native model importer (see model_import.h).
final class TModelImporter extends Opaque {}

/// Mesh transfer struct (see TMeshData.h). One FFI crossing per mesh instead
/// of one per attribute; the native side mallocs the buffers/strings and the
/// caller releases them with [MeshData_dispose].
final class TMeshData extends Struct {
  external Pointer<Char> name;

  external Pointer<Char> materialName;

  external Pointer<Float> vertices;

  @Int()
  external int vertexCount;

  external Pointer<Float> normals;

  @Int()
  external int normalCount;

  external Pointer<Float> uvs;

  @Int()
  external int uvCount;

  external Pointer<Uint32> indices;

  @Int()
  external int indexCount;

  @UnsignedInt()
  external int primitiveType;
}

/// Native primitive-type ids (APIBoundaryTypes.h); values match GL, with a
/// hole at 2, and align 1:1 with the [PrimitiveType] enum indices.
sealed class TPrimitiveType {
  /// !< points
  static const PRIMITIVETYPE_POINTS = 0;

  /// !< lines
  static const PRIMITIVETYPE_LINES = 1;

  /// !< line strip
  static const PRIMITIVETYPE_LINE_STRIP = 3;

  /// !< triangles
  static const PRIMITIVETYPE_TRIANGLES = 4;

  /// !< triangle strip
  static const PRIMITIVETYPE_TRIANGLE_STRIP = 5;
}

// Frees the buffers and strings held by a TMeshData and zeroes the struct.
@Native<Void Function(Pointer<TMeshData>)>(symbol: 'MeshData_dispose', isLeaf: true)
external void MeshData_dispose(Pointer<TMeshData> meshData);

@Native<Bool Function()>(symbol: 'ModelImporter_isSupported', isLeaf: true)
external bool ModelImporter_isSupported();

@Native<Pointer<TModelImporter> Function(Pointer<Uint8>, Size, Pointer<Char>)>(
  symbol: 'ModelImporter_loadFromBuffer',
)
external Pointer<TModelImporter> ModelImporter_loadFromBuffer(
  Pointer<Uint8> data,
  int size,
  Pointer<Char> extensionHint,
);

@Native<Int Function(Pointer<TModelImporter>)>(symbol: 'ModelImporter_getMeshCount', isLeaf: true)
external int ModelImporter_getMeshCount(Pointer<TModelImporter> importer);

@Native<Int Function(Pointer<TModelImporter>, Int, Pointer<TMeshData>)>(
  symbol: 'ModelImporter_getMesh',
  isLeaf: true,
)
external int ModelImporter_getMesh(Pointer<TModelImporter> importer, int meshIndex, Pointer<TMeshData> outMesh);

@Native<Void Function(Pointer<TModelImporter>)>(symbol: 'ModelImporter_destroy', isLeaf: true)
external void ModelImporter_destroy(Pointer<TModelImporter> importer);

@Native<Bool Function()>(symbol: 'ModelExporter_isSupported', isLeaf: true)
external bool ModelExporter_isSupported();

@Native<Pointer<Uint8> Function(Pointer<TMeshData>, Int, Pointer<Char>, Pointer<Int64>)>(
  symbol: 'ModelExporter_exportToBuffer',
)
external Pointer<Uint8> ModelExporter_exportToBuffer(
  Pointer<TMeshData> meshes,
  int meshCount,
  Pointer<Char> formatId,
  Pointer<Int64> outSize,
);

@Native<Void Function(Pointer<Uint8>)>(symbol: 'ModelExporter_disposeBuffer', isLeaf: true)
external void ModelExporter_disposeBuffer(Pointer<Uint8> data);
