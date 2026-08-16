#pragma once

// Trimmed-down port of thermion's native/include/c_api/APIExport.h: only the
// symbol-visibility machinery the model import/export C API needs. The
// EMSCRIPTEN/stdbool parts of the original are not used by this package.

#ifdef _WIN32
#ifdef IS_DLL
#define EMSCRIPTEN_KEEPALIVE __declspec(dllimport)
#else
#define EMSCRIPTEN_KEEPALIVE __declspec(dllexport)
#endif
#else
#ifndef EMSCRIPTEN_KEEPALIVE
#define EMSCRIPTEN_KEEPALIVE __attribute__((visibility("default")))
#endif
#endif

#ifdef _WIN32
// The prebuilt assimp archive in the Filament R2 artifacts is linked on
// Windows by name through the linker's library search path (set to the
// artifact extraction directory by hook/build.dart), mirroring thermion's
// ThermionWin32.h convention. FBX's binary tokenizer needs zlib's inflate,
// hence z.lib alongside assimp.lib.
#pragma comment(lib, "assimp.lib")
#pragma comment(lib, "z.lib")
#endif
