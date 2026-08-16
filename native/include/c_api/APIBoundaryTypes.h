#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

// Trimmed-down port of thermion's native/include/c_api/APIBoundaryTypes.h:
// only TPrimitiveType is needed at this package's FFI boundary (the mesh
// transfer struct reports the primitive type of each parsed mesh). Values
// match filament::PrimitiveType so RawMesh.primitiveType maps 1:1 with the
// thermion-side enum.

enum TPrimitiveType {
	// don't change the enums values (made to match GL)
	PRIMITIVETYPE_POINTS         = 0,    //!< points
	PRIMITIVETYPE_LINES          = 1,    //!< lines
	PRIMITIVETYPE_LINE_STRIP     = 3,    //!< line strip
	PRIMITIVETYPE_TRIANGLES      = 4,    //!< triangles
	PRIMITIVETYPE_TRIANGLE_STRIP = 5     //!< triangle strip
};
typedef enum TPrimitiveType TPrimitiveType;

#ifdef __cplusplus
}
#endif
