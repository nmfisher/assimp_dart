/// Unified model-file import/export facade.
///
/// Every path that decomposes a model file into flat meshes goes through
/// [ModelFileImporter] and produces [RawMesh]es; [ModelFileExporter] writes
/// those meshes back out to a model file.
///
/// Ported from thermion_dart's model_import barrel. CgltfImporter is not
/// ported: it parses through the cgltf code compiled into thermion's
/// Filament build, which this standalone package does not link.
export 'src/model_file_importer.dart';
export 'src/model_file_exporter.dart';
export 'src/raw_mesh.dart';
export 'src/assimp_importer.dart';
export 'src/assimp_exporter.dart';
