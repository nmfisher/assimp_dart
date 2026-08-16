import 'package:assimp_dart/src/model_import/src/raw_mesh.dart';
// PrimitiveType is hidden: both packages export one (assimp_dart's mirrors
// the mesh-side ids, thermion's the render-side ones) and nothing here names
// the type unqualified.
import 'package:thermion_dart/thermion_dart.dart' hide PrimitiveType;

/// Bridge from this package's import result to thermion's render-side
/// geometry, ported from thermion_dart's RawMesh.toGeometry
/// (feat/assimp-integration, thermion_dart/lib/src/model_import/src/
/// raw_mesh.dart) now that assimp_dart owns the mesh side.
extension RawMeshGeometry on RawMesh {
  /// Creates a thermion [Geometry] ready to hand to `createGeometry`.
  ///
  /// Positions/normals (and unflipped UVs) flow through as the same
  /// typed-data views this mesh exposes; only UV flipping and USHORT index
  /// narrowing allocate. Keep this mesh undisposed until the geometry has
  /// been uploaded (see [RawMesh.dispose]).
  ///
  /// [flipUvs] flips UV coordinates vertically (v = 1.0 - v) when the source
  /// format uses a bottom-left UV origin (most formats do; Filament uses
  /// top-left). Flipping happens here only, never in native Assimp, so it is
  /// never double-applied.
  Geometry toGeometry({
    bool flipUvs = false,
    bool createDummyColors = true,
    bool createDummyUvs = true,
  }) {
    final Float32List? processedUvs =
        uvs.isEmpty ? null : (flipUvs ? RawMesh.flipUVs(uvs) : uvs);

    final indexType = indices.length <= 65535 ? IndexType.USHORT : IndexType.UINT;

    final List<int> convertedIndices;
    if (indexType == IndexType.USHORT) {
      // Narrow through a typed list — no boxed per-element allocation.
      convertedIndices = Uint16List.fromList(indices);
    } else {
      convertedIndices = indices;
    }

    return Geometry(
      positions,
      convertedIndices,
      normals: normals.isEmpty ? null : normals,
      uvs: processedUvs,
      indexType: indexType,
      createDummyColors: createDummyColors,
      createDummyUvs: createDummyUvs,
    );
  }
}
