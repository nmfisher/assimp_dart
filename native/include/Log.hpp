#pragma once

// Trimmed-down port of thermion's native/include/Log.hpp: no emscripten,
// Android or Objective-C paths — this library targets desktop platforms
// (Linux, Windows, macOS) where printf is always available.

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <iostream>

static void Log(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);

    vprintf(fmt, args);
    std::cout << std::endl;

    va_end(args);
}

#if defined(_WIN32) || defined(_WIN64)
#define __FILENAME__ (strrchr(__FILE__, '\\') ? strrchr(__FILE__, '\\') + 1 : __FILE__)
#else
#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#endif

#ifdef ENABLE_TRACING
#define TRACE(fmt, ...) Log("TRACE %s:%d " fmt, __FILENAME__, __LINE__, ##__VA_ARGS__)
#else
#define TRACE(fmt, ...) ((void)0)
#endif

#define ERROR(fmt, ...) Log("Error: %s:%d " fmt, __FILENAME__, __LINE__, ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) Log("Error: %s:%d " fmt, __FILENAME__, __LINE__, ##__VA_ARGS__)
