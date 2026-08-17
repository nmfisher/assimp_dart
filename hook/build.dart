import 'dart:io';
import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

// Build hook for assimp_dart: downloads the prebuilt libassimp archive (and
// the matching assimp headers) from this repository's GitHub Releases
// (published by .github/workflows/build-libassimp.yml to the release tagged
// libassimp-<filament.version>),
// then compiles native/src/c_api and links everything into a single
// libassimp_dart shared library. Ported from thermion_dart/hook/build.dart
// (branch feat/assimp-integration); everything not needed for model
// import/export — the whole Filament link, plugins, materials, web
// artifacts, user_defines.assimp — is dropped.
//
// This package is ALWAYS assimp-enabled: there is no compile-time switch and
// no `assimp` user_define. The only user_define is `mode` (debug|release,
// default release), which selects the release artifact variant.

/// Writes build log lines to .dart_tool/assimp_dart/log/build.log and mirrors
/// SEVERE records to stderr (same convention as thermion_dart's
/// lib/src/logging/log.dart, inlined here to keep the hook self-contained).
Logger createBuildLogger(String packageRoot, String logFilename) {
  var logPath = path.join(packageRoot, '.dart_tool', 'assimp_dart', 'log', logFilename);
  var logFile = File(logPath);
  if (!logFile.parent.existsSync()) {
    logFile.parent.createSync(recursive: true);
  }

  hierarchicalLoggingEnabled = true;
  final logger = Logger('assimp_dart.build')
    ..level = Level.ALL
    ..onRecord.listen((record) {
      logFile.writeAsStringSync(record.message + '\n', mode: FileMode.append, flush: true);
      // Tee SEVERE records to stderr so subprocess errors (cl.exe, clang, ld)
      // actually surface to whoever's watching the build; the thrown
      // ProcessException only carries the command + exit code.
      if (record.level >= Level.SEVERE) {
        stderr.writeln(record.message);
      }
    });
  return logger;
}

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    final packageRoot = input.packageRoot;
    final pkgRootFilePath = packageRoot.toFilePath(windows: Platform.isWindows);

    final logger = createBuildLogger(pkgRootFilePath, 'build.log');

    if (!input.config.buildCodeAssets) {
      // Web/other targets without code assets: this package has no wasm
      // build, so there is nothing to produce.
      logger.info('buildCodeAssets is false; nothing to build for this target');
      return;
    }

    final config = input.config;
    final packageName = input.packageName;

    final targetOS = config.code.targetOS;
    final targetArchitecture = config.code.targetArchitecture;

    // Most users only need the release artifact; debug exists for
    // investigating native issues (set `mode: debug` under
    // hooks.user_defines.assimp_dart in the consuming package's pubspec).
    var buildMode = BuildMode.release;
    if (input.userDefines['mode'] == 'debug') {
      buildMode = BuildMode.debug;
    }

    logger.info('Building $packageName for $targetOS (${targetArchitecture.name}) in mode ${buildMode.name}');

    switch (targetOS) {
      case OS.linux:
      case OS.windows:
      case OS.macOS:
        break;
      default:
        throw Exception(
          'assimp_dart does not yet ship prebuilt libassimp artifacts for $targetOS. '
          'Supported: linux (x64/arm64), windows, macos.',
        );
    }

    final libResult = await getAssimpDir(
      packageRoot,
      targetOS,
      targetArchitecture,
      logger,
      buildMode,
    );
    final libDir = libResult.libDir.path;

    final sources = [
      path.join(pkgRootFilePath, 'native', 'src', 'c_api', 'TMeshData.cpp'),
      path.join(pkgRootFilePath, 'native', 'src', 'c_api', 'model_import.cpp'),
      path.join(pkgRootFilePath, 'native', 'src', 'c_api', 'model_export.cpp'),
    ];

    // The single-C++-ABI guard from thermion's hook: on Linux/macOS everything
    // linked into libassimp_dart.so must come from ONE C++ runtime (libc++).
    // A libassimp.a compiled against libstdc++ leaves _ZNSt7__cxx11-mangled
    // references undefined, pulls libstdc++ in as a second runtime, and
    // crashes inside libc++abi's RTTI/exception machinery (the Linux x64 FBX
    // round-trip crash seen in thermion's CI; see PR #195). Fail the build
    // loudly instead of surfacing that as a mysterious test crash.
    if (targetOS != OS.windows) {
      await _assertSingleCppAbi(path.join(libDir, 'libassimp.a'), logger);
    }

    final defines = <String, String?>{};

    final flags = <String>[];

    // Include directories:
    //  - `native/include`: this package's own headers (c_api/, Log.hpp),
    //    committed in-tree.
    //  - the assimp headers bundled in the same release artifact under
    //    include/third_party/libassimp/include/, extracted by getAssimpDir —
    //    no vendored copy in-tree, so headers always match the linked
    //    libassimp.a.
    // Absolute paths: the compiler runs with the hook's build output
    // directory as cwd (native_toolchain_c's runProcess `cd`s there), so a
    // relative "native/include" resolves to nothing — on Windows that fails
    // cl.exe with C1083 "Cannot open include file: 'c_api/TMeshData.h'".
    final includeDirs = <String>[
      path.join(pkgRootFilePath, 'native', 'include'),
      libResult.assimpIncludeDir.path,
    ];

    if (targetOS != OS.windows) {
      // Match the published libassimp.a, which is built with libc++ (see
      // _assertSingleCppAbi): compiling this library against libstdc++ would
      // put two C++ runtimes in one process again.
      flags.addAll(['-stdlib=libc++', '-std=c++17']);

      if (buildMode == BuildMode.debug) {
        flags.addAll(['-g', '-O0']);
      }

      // Static archives are implementation details of libassimp_dart.so; the
      // FBX binary tokenizer needs zlib's inflate, so link the system zlib
      // (Windows links the z.lib bundled in the artifact instead, via the
      // #pragma comment(lib) directives in APIExport.h).
      //
      // The linker resolves left-to-right and CBuilder places `flags` BEFORE
      // the sources, so a plain -lassimp sees no pending references and pulls
      // nothing (the resulting .so fails at dlopen with "undefined symbol:
      // Assimp::Importer::Importer()"). Whole-archive (Linux) / -force_load
      // (macOS ld64) includes every archive member regardless of position —
      // the same wrap thermion's hook uses for its Linux link. MSVC's linker
      // iterates libraries until stable, so Windows needs no equivalent.
      flags.addAll([
        if (targetOS == OS.linux) ...[
          '-Wl,--whole-archive',
          '-lassimp',
          '-Wl,--no-whole-archive',
        ] else if (targetOS == OS.macOS) ...[
          '-force_load',
          path.join(libDir, 'libassimp.a'),
        ],
        if (targetOS != OS.macOS) '-lz',
        '-lc++',
        '-L$libDir',
      ]);
    } else {
      defines['WIN32'] = '1';
      defines['_DLL'] = '1';
      if (buildMode == BuildMode.debug) {
        defines['_DEBUG'] = '1';
      } else {
        defines['RELEASE'] = '1';
        defines['NDEBUG'] = '1';
      }
      flags.addAll([
        '/std:c++20',
        // C++ exceptions ARE used: assimp parses by throwing
        // (DeadlyImportError and friends) and the FFI entry points convert
        // the throws to error returns. /EHsc is required for those catch-all
        // barriers to catch anything at all under cl.exe.
        '/EHsc',
        if (buildMode == BuildMode.debug) ...['/MDd', '/Zi'],
        if (buildMode == BuildMode.release) '/MD',
        ...defines.keys.map((k) => '/D$k=${defines[k]}'),
        // Include dirs as explicit /I flags (mirrors thermion's hook, which
        // passes `includes:` only for non-Windows targets).
        ...includeDirs.map((d) => '/I$d'),
      ]);
      // assimp.lib + z.lib are linked through the #pragma comment(lib)
      // directives in native/include/c_api/APIExport.h; the linker finds them
      // via `libraryDirectories` below.
    }

    final cbuilder = CBuilder.library(
      name: packageName,
      language: Language.cpp,
      assetName: 'assimp_dart.dart',
      sources: sources,
      includes: targetOS == OS.windows ? [] : includeDirs,
      defines: targetOS == OS.windows ? {} : defines,
      flags: flags,
      libraryDirectories: [libDir],
    );

    await cbuilder.run(input: input, output: output, logger: logger);

    logger.info('Built lib${packageName} for $targetOS (${targetArchitecture.name})');
  });
}

/// Throws if the prebuilt [archive] (libassimp.a) carries libstdc++-mangled
/// references, i.e. was not built with the same C++ runtime as the rest of
/// this link. Ported verbatim from thermion's hook: symbol names appear
/// verbatim in the archive's symbol table, so a raw byte scan for the
/// libstdc++ std::string ABI marker is sufficient — no nm/ar parsing needed.
/// Chunks are read with an overlap so a marker straddling a read boundary is
/// still found.
Future<void> _assertSingleCppAbi(String archivePath, Logger logger) async {
  final marker = '_ZNSt7__cxx11'.codeUnits;
  final archive = File(archivePath);
  if (!archive.existsSync()) {
    throw Exception(
      'libassimp.a not found at $archivePath — the libassimp artifact zip is '
      'incomplete. Delete the enclosing directory and rebuild to re-download.',
    );
  }
  logger.info('Checking C++ ABI of $archivePath');
  var carry = <int>[];
  await for (final chunk in archive.openRead()) {
    final data = carry.isEmpty ? chunk : [...carry, ...chunk];
    final first = marker[0];
    for (var i = 0; i + marker.length <= data.length; i++) {
      if (data[i] != first) continue;
      var matches = true;
      for (var j = 1; j < marker.length; j++) {
        if (data[i + j] != marker[j]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        throw Exception(
          'libassimp.a at $archivePath references libstdc++ symbols '
          '(_ZNSt7__cxx11...): this Filament artifact was built WITHOUT '
          '-stdlib=libc++, so it cannot be linked into libassimp_dart.so '
          'together with the libc++-compiled sources of this package. '
          "Republish the artifact from this repository's 'Build libassimp' "
          'workflow (platform for this target, publish=true), then delete '
          '$archivePath (and the enclosing extraction directory) so the next '
          'build re-downloads it.',
        );
      }
    }
    carry = data.length < marker.length
        ? data.toList()
        : data.sublist(data.length - marker.length + 1);
  }
  logger.info('libassimp.a is a libc++ build (no libstdc++ references)');
}

// filament.version lives at the package root of this repository and pins the
// release artifact generation ("https://github.com/google/filament v1.75.0").
String _getFilamentVersion(Uri packageRoot) {
  final pkgPath = packageRoot.toFilePath(windows: Platform.isWindows);
  final versionFile = File(path.join(pkgPath, 'filament.version'));
  if (versionFile.existsSync()) {
    final parts = versionFile.readAsStringSync().trim().split(RegExp(r'\s+'));
    // Format: "<repo> <version>" - return the version (second field)
    return parts.length >= 2 ? parts[1] : parts[0];
  }
  throw Exception('filament.version not found at ${versionFile.path}');
}

String _getArtifactUrl(String version, String platform, String mode) {
  final tag = 'libassimp-$version';
  return 'https://github.com/nmfisher/assimp_dart/releases/download/'
      '$tag/libassimp-$version-$platform-$mode.zip';
}

//
// Download the prebuilt libassimp artifact zip for the target platform from
// this repository's GitHub Releases and extract what this package needs:
//
//   - libassimp.a        (assimp.lib + z.lib on Windows)
//   - include/third_party/libassimp/include/**  (the assimp headers)
//
// The zips are assimp-only (built by this repository's "Build libassimp"
// workflow) with the inner layout the Filament artifact zips used to carry on
// R2, so the extraction filter below works unchanged. Same caching scheme as
// thermion's hook: a `success` token next to the zip marks a completed
// download+extraction and short-circuits subsequent builds.
//
Future<({Directory libDir, Directory assimpIncludeDir})> getAssimpDir(
  Uri packageRoot,
  OS targetOS,
  Architecture targetArchitecture,
  Logger logger,
  BuildMode buildMode, {
  bool isIOSSimulator = false,
}) async {
  var platform = targetOS.toString().toLowerCase();

  final version = _getFilamentVersion(packageRoot);
  var mode = buildMode == BuildMode.debug ? 'debug' : 'release';

  if (platform == 'windows') {
    if (targetArchitecture != Architecture.x64) {
      throw Exception('Unsupported architecture for Windows: $targetArchitecture');
    }
  } else if (platform == 'linux') {
    // Linux x64 keeps the legacy zip URL; arm64 consumers fetch the
    // arch-suffixed zip and use an arch-scoped cache dir so the two never
    // collide (same scheme as thermion's hook).
    if (targetArchitecture == Architecture.arm64) {
      platform = 'linux-arm64';
    } else if (targetArchitecture != Architecture.x64) {
      throw Exception('Unsupported architecture for Linux: $targetArchitecture');
    }
  }

  // arm64 consumers use an arch-scoped cache dir so the two Linux variants
  // never collide.
  final archSuffix = platform == 'linux-arm64' ? 'arm64' : null;
  final libDir = Directory(
    path.joinAll(
      [
        packageRoot.toFilePath(windows: Platform.isWindows),
        '.dart_tool',
        'assimp_dart',
        'lib',
        version,
        platform,
        mode,
        if (archSuffix != null) archSuffix,
      ],
    ),
  );

  logger.info('Searching for prebuilt libassimp under ${libDir.path}');

  final url = _getArtifactUrl(version, platform, mode);
  final filename = url.split('/').last;

  final successToken = File(path.join(libDir.path, 'success'));
  final zipFile = File(path.join(libDir.path, filename));

  if (zipFile.existsSync()) {
    final zipBytes = await zipFile.readAsBytes();
    final zipHash = md5.convert(zipBytes);
    logger.info('Existing artifact zip hash: $zipHash, size: ${zipBytes.length} bytes (${zipFile.path})');
  }

  if (!successToken.existsSync()) {
    if (zipFile.existsSync()) {
      zipFile.deleteSync();
    }

    if (!zipFile.parent.existsSync()) {
      zipFile.parent.createSync(recursive: true);
    }

    logger.info(
      'Downloading prebuilt libassimp for $platform/$mode from $url '
      '(extraction: libassimp archive + assimp headers only)',
    );
    final request = await HttpClient().getUrl(Uri.parse(url));
    final response = await request.close();

    if (response.statusCode != 200) {
      throw Exception('Artifact not found at $url');
    }

    await response.pipe(zipFile.openWrite());

    final downloadedBytes = await zipFile.readAsBytes();
    final downloadedHash = md5.convert(downloadedBytes);
    logger.info(
      'Downloaded artifact zip hash: $downloadedHash, size: ${downloadedBytes.length} bytes (${zipFile.path})',
    );

    final archive = ZipDecoder().decodeBytes(downloadedBytes);

    // The Windows zips store entries with backslash separators; normalise so
    // path.join produces valid paths on any host.
    String normalise(String name) => name.replaceAll('\\', '/');

    // libassimp.a on Linux/macOS, assimp.lib on Windows. Windows also needs
    // the bundled z.lib (see APIExport.h).
    final wantedLibs = {
      if (targetOS == OS.windows) 'assimp.lib' else 'libassimp.a',
      if (targetOS == OS.windows) 'z.lib',
    };

    for (final file in archive) {
      final name = normalise(file.name);
      final topLevel = path.basename(name);
      final isAssimpHeader = name.startsWith('include/third_party/libassimp/');
      final isWantedLib = wantedLibs.contains(topLevel);
      if (!file.isFile || !(isAssimpHeader || isWantedLib)) {
        continue;
      }
      final f = File(path.join(libDir.path, name));
      await f.create(recursive: true);
      await f.writeAsBytes(file.content as List<int>);
    }
    successToken.writeAsStringSync('SUCCESS');
  }

  final assimpIncludeDir = Directory(
    path.join(libDir.path, 'include', 'third_party', 'libassimp', 'include'),
  );
  final assimpLib = File(
    path.join(libDir.path, targetOS == OS.windows ? 'assimp.lib' : 'libassimp.a'),
  );
  if (!assimpLib.existsSync() || !assimpIncludeDir.existsSync()) {
    throw Exception(
      'Extracted artifact at ${libDir.path} is incomplete '
      '(missing ${assimpLib.path} or ${assimpIncludeDir.path}). '
      'Delete the directory and rebuild to re-download.',
    );
  }

  return (libDir: libDir, assimpIncludeDir: assimpIncludeDir);
}
