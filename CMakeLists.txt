cmake_minimum_required(VERSION 3.14)

cmake_policy(SET CMP0091 NEW)

project(tjs LANGUAGES C CXX)

include(ExternalProject)
include(GNUInstallDirs)

if (NOT CMAKE_BUILD_TYPE)
    message(STATUS "No build type selected, default to Release")
    set(CMAKE_BUILD_TYPE "Release")
endif()
message(STATUS "Building in ${CMAKE_BUILD_TYPE} mode")
message(STATUS "Building with ${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION} on ${CMAKE_SYSTEM}")

set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_C_STANDARD 11)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    list(APPEND tjs_cflags /experimental:c11atomics)
else()
    list(APPEND tjs_cflags -Wall -g)
    if(UNIX)
        # Treat warnings as errors, but only on Unix; Windows toolchains warn differently.
        list(APPEND tjs_cflags -Werror)
    endif()
    if (CMAKE_BUILD_TYPE MATCHES "Debug")
        list(APPEND tjs_cflags -ggdb -O0 -fno-omit-frame-pointer)
    endif()
endif()

set(TJS__VERSION_MAJOR 26)
set(TJS__VERSION_MINOR 6)
set(TJS__VERSION_PATCH 0)
set(TJS__VERSION_SUFFIX "")
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/version.h.in"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/version.h"
)

macro(xoption OPTION_NAME OPTION_TEXT OPTION_DEFAULT)
    option(${OPTION_NAME} ${OPTION_TEXT} ${OPTION_DEFAULT})
    if(DEFINED ENV{${OPTION_NAME}})
        # Allow setting the option through an environment variable
        set(${OPTION_NAME} $ENV{${OPTION_NAME}})
    endif()
    if(${OPTION_NAME})
        add_definitions(-D${OPTION_NAME})
    endif()
    message(STATUS "  ${OPTION_NAME}: ${${OPTION_NAME}}")
endmacro()

xoption(BUILD_WITH_MIMALLOC "If ON (default), build with mimalloc" ON)
xoption(BUILD_WITH_FFI "If ON (default), build with libffi (the tjs:ffi module)" ON)
xoption(BUILD_WITH_ASAN "Build with AddressSanitizer" OFF)
xoption(BUILD_WITH_UBSAN "Build with UndefinedBehaviorSanitizer" OFF)
xoption(BUILD_WITH_GC_STRESS "Force a full GC before every JS allocation (QuickJS FORCE_GC_AT_MALLOC)" OFF)
xoption(BUILD_WITH_WASM "If ON (default), build with WASM/WAMR support" ON)
xoption(BUILD_WITH_SQLITE "If ON (default), build with SQLite (the tjs:sqlite module)" ON)
xoption(BUILD_WITH_ADA "If ON (default), build the Ada-backed URL and URLSearchParams globals" ON)
xoption(BUILD_WITH_WEBCRYPTO "If ON (default), build SubtleCrypto. The OS-backed crypto.getRandomValues and crypto.randomUUID APIs remain available when OFF" ON)
xoption(BUILD_WITH_LWS "If ON (default), build the libwebsockets/mbedTLS secure network stack: fetch, WebSocket, HTTP server, tjs:tls sockets, http(s) module imports and the embedded CA store. mbedcrypto is always built (tjs:hashing needs it) - OFF drops only the TLS/X.509 halves" ON)
xoption(BUILD_WITH_STRIP "If ON, strip the tjs binary after linking" OFF)
xoption(BUILD_WITH_LTO "If ON, enable link-time optimization" OFF)
xoption(BUILD_WITH_GC_SECTIONS "If ON, compile with per-function/data sections and link with dead-code stripping" OFF)

if(BUILD_WITH_GC_STRESS)
    message(STATUS "GC stress mode enabled (FORCE_GC_AT_MALLOC)")
    # quickjs.c only runs a GC when this is defined; the definition is set at
    # directory scope here so it propagates to the deps/quickjs subdirectory
    # added below.
    add_compile_definitions(FORCE_GC_AT_MALLOC)
endif()

if(BUILD_WITH_ASAN)
    message(STATUS "AddressSanitizer enabled")
    if(BUILD_WITH_MIMALLOC)
        message(FATAL_ERROR "BUILD_WITH_ASAN and BUILD_WITH_MIMALLOC cannot be used together")
    endif()
    add_compile_definitions(TJS__HAS_ASAN)
    if(MSVC)
        add_compile_options(/fsanitize=address)
    else()
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer -fno-sanitize-recover=all)
        add_link_options(-fsanitize=address)
    endif()
endif()

if(BUILD_WITH_UBSAN)
    message(STATUS "UndefinedBehaviorSanitizer enabled")
    if(MSVC)
        message(FATAL_ERROR "BUILD_WITH_UBSAN is not supported with MSVC")
    endif()
    add_compile_options(-fsanitize=undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=undefined)
endif()

if(BUILD_WITH_LTO)
    include(CheckIPOSupported)
    check_ipo_supported(RESULT _ipo_supported OUTPUT _ipo_output)
    if(_ipo_supported)
        message(STATUS "LTO enabled")
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
    else()
        message(WARNING "LTO requested but not supported: ${_ipo_output}")
    endif()
endif()

if(BUILD_WITH_GC_SECTIONS)
    if(MSVC)
        add_compile_options(/Gy)
    else()
        add_compile_options(-ffunction-sections -fdata-sections)
    endif()
endif()

###
### Core library / executables
###

# The native initializers and bootstrap bytecode must be selected as one unit:
# both URL and full WebCrypto are dereferenced while the polyfills bundle is
# evaluated. Shipping mismatched bytecode would abort every process at boot.
if(BUILD_WITH_ADA)
    if(BUILD_WITH_WEBCRYPTO)
        set(TJS_POLYFILLS_BUNDLE src/bundles/c/core/polyfills.c)
    else()
        set(TJS_POLYFILLS_BUNDLE src/bundles/c/core/no-webcrypto/polyfills.c)
    endif()
else()
    if(BUILD_WITH_WEBCRYPTO)
        set(TJS_POLYFILLS_BUNDLE src/bundles/c/core/no-ada/polyfills.c)
    else()
        set(TJS_POLYFILLS_BUNDLE src/bundles/c/core/minimal/polyfills.c)
    endif()
endif()

add_library(tjs STATIC
    src/builtins.c
    src/error.c
    src/eval.c
    src/mem.c
    src/modules.c
    src/tbuf.c
    src/signals.c
    src/text-coding.c
    src/timers.c
    src/utils.c
    src/version.c
    src/vm.c
    src/worker.c
    src/mod_channel.c
    src/mod_dns.c
    src/mod_engine.c
    src/mod_fs.c
    src/mod_fswatch.c
    src/mod_hashing.c
    src/mod_os.c
    src/mod_process.c
    src/mod_miniz.c
    src/mod_streams.c
    src/mod_sys.c
    src/mod_udp.c
    src/bundles/c/core/core.c
    ${TJS_POLYFILLS_BUNDLE}
    src/bundles/c/core/run-main.c
    src/bundles/c/core/run-repl.c
    src/bundles/c/core/worker-bootstrap.c
)

if(BUILD_WITH_ADA)
    target_sources(tjs PRIVATE src/url.c)
    target_compile_definitions(tjs PRIVATE TJS_HAVE_ADA)
endif()

if(BUILD_WITH_WEBCRYPTO)
    target_sources(tjs PRIVATE
        src/ed25519.c
        src/webcrypto.c
    )
    target_compile_definitions(tjs PRIVATE TJS_HAVE_WEBCRYPTO)
endif()

if(BUILD_WITH_LWS)
    # The lws-backed network stack plus the pieces only it consumes: tjs:tls
    # (mbedTLS TLS sockets) and the embedded CA bundle (cacert.c, used by both
    # lws-utils.c and mod_tls.c). The JS polyfills capture these natives
    # lazily (const WS = core.WebSocket, no member access at bootstrap), so a
    # build without them boots fine and fails only at use.
    target_sources(tjs PRIVATE
        src/cacert.c
        src/httpclient.c
        src/httpserver.c
        src/lws-evlib.c
        src/lws-utils.c
        src/mod_tls.c
        src/ws.c
    )
    target_compile_definitions(tjs PRIVATE TJS_HAVE_LWS)
endif()

if(UNIX)
    target_sources(tjs PRIVATE src/mod_posix-socket.c)
endif()

if(BUILD_WITH_WASM)
    target_sources(tjs PRIVATE src/wasm.c)
    target_compile_definitions(tjs PRIVATE TJS_HAVE_WASM)
endif()

if(BUILD_WITH_SQLITE)
    target_sources(tjs PRIVATE src/mod_sqlite3.c)
    target_compile_definitions(tjs PRIVATE TJS_HAVE_SQLITE)
endif()

set_target_properties(tjs PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON
    OUTPUT_NAME tjs_core
)

string(TOLOWER ${CMAKE_SYSTEM_NAME} TJS_PLATFORM)
target_compile_options(tjs PRIVATE ${tjs_cflags})
target_compile_definitions(tjs PRIVATE TJS__PLATFORM="${TJS_PLATFORM}")

if(WIN32)
    target_compile_definitions(tjs PRIVATE WIN32_LEAN_AND_MEAN)
endif()

target_include_directories(tjs PUBLIC src)

###
### V8 wire-format compatibility module (Zig)
###

find_program(TJS_ZIG_EXECUTABLE NAMES zig REQUIRED)
set(TJS_ZIG_TARGET "" CACHE STRING "Zig target triple for the tjs:v8 compatibility library")

if(NOT TJS_ZIG_TARGET)
    set(_tjs_zig_arch "${CMAKE_SYSTEM_PROCESSOR}")
    if(APPLE AND CMAKE_OSX_ARCHITECTURES)
        set(_tjs_osx_architectures ${CMAKE_OSX_ARCHITECTURES})
        list(LENGTH _tjs_osx_architectures _tjs_osx_architecture_count)
        if(_tjs_osx_architecture_count EQUAL 1)
            list(GET _tjs_osx_architectures 0 _tjs_zig_arch)
        endif()
    elseif(ANDROID AND ANDROID_ABI)
        set(_tjs_zig_arch "${ANDROID_ABI}")
    endif()
    string(TOLOWER "${_tjs_zig_arch}" _tjs_zig_arch)

    if(_tjs_zig_arch MATCHES "^(arm64|arm64-v8a|aarch64)$")
        set(_tjs_zig_arch "aarch64")
    elseif(_tjs_zig_arch MATCHES "^(amd64|x64|x86_64)$")
        set(_tjs_zig_arch "x86_64")
    else()
        message(FATAL_ERROR "Set TJS_ZIG_TARGET explicitly for unsupported architecture: ${_tjs_zig_arch}")
    endif()

    if(APPLE)
        set(TJS_ZIG_TARGET "${_tjs_zig_arch}-macos")
    elseif(ANDROID)
        set(TJS_ZIG_TARGET "${_tjs_zig_arch}-linux-android")
    elseif(WIN32)
        set(TJS_ZIG_TARGET "${_tjs_zig_arch}-windows-gnu")
    elseif(CMAKE_C_COMPILER_TARGET MATCHES "musl" OR CMAKE_C_LIBRARY_ARCHITECTURE MATCHES "musl")
        set(TJS_ZIG_TARGET "${_tjs_zig_arch}-linux-musl")
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(TJS_ZIG_TARGET "${_tjs_zig_arch}-linux-gnu")
    else()
        message(FATAL_ERROR "Set TJS_ZIG_TARGET explicitly for unsupported system: ${CMAKE_SYSTEM_NAME}")
    endif()
endif()
message(STATUS "Building tjs:v8 Zig library for ${TJS_ZIG_TARGET}")

if(CMAKE_BUILD_TYPE MATCHES "Debug")
    set(TJS_ZIG_OPTIMIZE Debug)
elseif(CMAKE_BUILD_TYPE MATCHES "MinSizeRel")
    set(TJS_ZIG_OPTIMIZE ReleaseSmall)
else()
    set(TJS_ZIG_OPTIMIZE ReleaseFast)
endif()

if(MSVC)
    set(TJS_ZIG_LIBRARY "${CMAKE_BINARY_DIR}/tjs_v8.lib")
else()
    set(TJS_ZIG_LIBRARY "${CMAKE_BINARY_DIR}/libtjs_v8.a")
endif()
set(TJS_ZIG_BUILD_LIBRARY "${TJS_ZIG_LIBRARY}")
set(TJS_ZIG_CACHE_DIR "${CMAKE_BINARY_DIR}/zig-cache")
set(TJS_ZIG_GLOBAL_CACHE_DIR "${CMAKE_BINARY_DIR}/zig-global-cache")
set(TJS_ZIG_SYSTEM_INCLUDE_ARGS)
set(TJS_ZIG_PIC_ARGS)
set(TJS_ZIG_RUNTIME_ARGS)
set(TJS_ZIG_POST_BUILD_COMMANDS)
# Zig 0.16 defaults GNU/Linux archives to PIC, but not musl or Android;
# both surrounding toolchains link tjs as a position-independent executable.
# Match optional Zig OS and ABI versions (for example linux.4.19-musl and
# linux-android.21) without changing GNU or Windows targets.
if(TJS_ZIG_TARGET MATCHES "-linux([.][^-]+)?-(musl|android)([.][^-]+)?$")
    list(APPEND TJS_ZIG_PIC_ARGS -fPIC)
endif()
# A C/C++ final link does not add Zig's compiler runtime. x86_64 macOS Debug
# emits out-of-line stack probes, so keep their implementation in the archive.
if(TJS_ZIG_TARGET MATCHES "^x86_64-macos([.][^-]+)?$" AND TJS_ZIG_OPTIMIZE STREQUAL "Debug")
    list(APPEND TJS_ZIG_RUNTIME_ARGS -fcompiler-rt)
    set(TJS_ZIG_BUILD_LIBRARY "${CMAKE_BINARY_DIR}/libtjs_v8_zig.a")
    set(TJS_ZIG_REPACK_DIR "${CMAKE_BINARY_DIR}/tjs-v8-zig-repack")
    # Zig 0.16 does not align the added compiler_rt.o member as ld64 requires;
    # re-archiving the extracted objects with the platform archiver fixes that.
    list(APPEND TJS_ZIG_POST_BUILD_COMMANDS
        COMMAND "${CMAKE_COMMAND}" -E remove_directory "${TJS_ZIG_REPACK_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${TJS_ZIG_REPACK_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E chdir "${TJS_ZIG_REPACK_DIR}" "${CMAKE_AR}" -x "${TJS_ZIG_BUILD_LIBRARY}"
        COMMAND "${CMAKE_COMMAND}" -E chdir "${TJS_ZIG_REPACK_DIR}" chmod 0644 libtjs_v8_zig_zcu.o compiler_rt.o
        COMMAND "${CMAKE_COMMAND}" -E remove -f "${TJS_ZIG_LIBRARY}"
        COMMAND "${CMAKE_AR}" rcs "${TJS_ZIG_LIBRARY}"
            "${TJS_ZIG_REPACK_DIR}/libtjs_v8_zig_zcu.o"
            "${TJS_ZIG_REPACK_DIR}/compiler_rt.o"
    )
endif()
# The GNU-target Zig archive must not parse MSVC's implicit headers; the surrounding build remains MSVC.
if(NOT TJS_ZIG_TARGET MATCHES "-windows-gnu$")
    foreach(_tjs_system_include IN LISTS CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES)
        list(APPEND TJS_ZIG_SYSTEM_INCLUDE_ARGS "-I${_tjs_system_include}")
    endforeach()
endif()
set(TJS_ZIG_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/mod_v8_compat.zig"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/tjs_qjs_allocator.zig"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/tjs_structs.zig"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/v8_serialize.zig"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/zig_c_bindings.zig"
)

add_custom_command(
    OUTPUT "${TJS_ZIG_LIBRARY}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${TJS_ZIG_CACHE_DIR}" "${TJS_ZIG_GLOBAL_CACHE_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env
        "ZIG_LOCAL_CACHE_DIR=${TJS_ZIG_CACHE_DIR}"
        "ZIG_GLOBAL_CACHE_DIR=${TJS_ZIG_GLOBAL_CACHE_DIR}"
        "${TJS_ZIG_EXECUTABLE}" build-lib "${CMAKE_CURRENT_SOURCE_DIR}/src/zig_c_bindings.zig"
        -target "${TJS_ZIG_TARGET}"
        "-O${TJS_ZIG_OPTIMIZE}"
        "-I${CMAKE_CURRENT_SOURCE_DIR}/deps/quickjs"
        "-I${CMAKE_CURRENT_SOURCE_DIR}/src"
        ${TJS_ZIG_SYSTEM_INCLUDE_ARGS}
        ${TJS_ZIG_PIC_ARGS}
        ${TJS_ZIG_RUNTIME_ARGS}
        -lc
        "-femit-bin=${TJS_ZIG_BUILD_LIBRARY}"
        --cache-dir "${TJS_ZIG_CACHE_DIR}"
        --global-cache-dir "${TJS_ZIG_GLOBAL_CACHE_DIR}"
    ${TJS_ZIG_POST_BUILD_COMMANDS}
    DEPENDS ${TJS_ZIG_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/deps/quickjs/quickjs.h"
    COMMENT "Building tjs:v8 Zig static library"
    COMMAND_EXPAND_LISTS
    VERBATIM
)
add_custom_target(tjs-v8-zig DEPENDS "${TJS_ZIG_LIBRARY}")
add_dependencies(tjs tjs-v8-zig)
# Keep this before qjs in the transitive link order: the Zig archive references
# public QuickJS symbols which the following qjs archive resolves.
target_link_libraries(tjs PUBLIC "${TJS_ZIG_LIBRARY}")

add_executable(tjs-cli
    src/cli.c
)
target_link_libraries(tjs-cli tjs)
set_target_properties(tjs-cli
    PROPERTIES OUTPUT_NAME tjs
)
# On Windows with MSVC the stack size if by default 1MB, same as our engine.
# Bump it up to 8MB.
if(WIN32)
    target_link_options(tjs-cli PRIVATE "/STACK:8388608")
endif()

if(BUILD_WITH_STRIP AND CMAKE_STRIP)
    add_custom_command(TARGET tjs-cli POST_BUILD
        COMMAND ${CMAKE_STRIP} $<TARGET_FILE:tjs-cli>
        COMMENT "Stripping tjs"
    )
endif()

if(BUILD_WITH_GC_SECTIONS)
    if(MSVC)
        target_link_options(tjs-cli PRIVATE /OPT:REF /OPT:ICF)
    elseif(APPLE)
        target_link_options(tjs-cli PRIVATE -Wl,-dead_strip)
    else()
        target_link_options(tjs-cli PRIVATE -Wl,--gc-sections)
    endif()
endif()

add_executable(tjsc EXCLUDE_FROM_ALL
    src/qjsc.c
)

###
### Dependencies
###

add_subdirectory(deps/quickjs EXCLUDE_FROM_ALL)
target_link_libraries(tjs PUBLIC qjs)
target_link_libraries(tjsc qjs)

set(TJS_ZIG_TEST_LINK_ARGS -lc)
if(UNIX AND NOT APPLE AND NOT ANDROID)
    list(APPEND TJS_ZIG_TEST_LINK_ARGS -lm -ldl -lpthread)
endif()
add_custom_target(v8-zig-test
    COMMAND "${CMAKE_COMMAND}" -E env
        "ZIG_LOCAL_CACHE_DIR=${TJS_ZIG_CACHE_DIR}"
        "ZIG_GLOBAL_CACHE_DIR=${TJS_ZIG_GLOBAL_CACHE_DIR}"
        "${TJS_ZIG_EXECUTABLE}" test "${CMAKE_CURRENT_SOURCE_DIR}/src/v8_serialize_test.zig"
        "$<TARGET_FILE:qjs>"
        -target "${TJS_ZIG_TARGET}"
        "-I${CMAKE_CURRENT_SOURCE_DIR}/deps/quickjs"
        "-I${CMAKE_CURRENT_SOURCE_DIR}/src"
        ${TJS_ZIG_SYSTEM_INCLUDE_ARGS}
        ${TJS_ZIG_TEST_LINK_ARGS}
        --cache-dir "${TJS_ZIG_CACHE_DIR}"
        --global-cache-dir "${TJS_ZIG_GLOBAL_CACHE_DIR}"
    DEPENDS qjs ${TJS_ZIG_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/src/v8_serialize_test.zig"
    COMMENT "Running tjs:v8 Zig tests"
    COMMAND_EXPAND_LISTS
    VERBATIM
    USES_TERMINAL
)

if(BUILD_WITH_MIMALLOC)
    option(MI_OVERRIDE "" OFF)
    option(MI_BUILD_SHARED "" OFF)
    option(MI_BUILD_STATIC "" ON)
    option(MI_BUILD_OBJECT "" OFF)
    option(MI_BUILD_TESTS "" OFF)
    if(CMAKE_BUILD_TYPE MATCHES "Debug")
        option(MI_GUARDED "" ON)
    endif()
    add_subdirectory(deps/mimalloc EXCLUDE_FROM_ALL)
    target_compile_definitions(tjs PRIVATE TJS__HAS_MIMALLOC)
    target_link_libraries(tjs PUBLIC mimalloc-static)
endif()

option(libuv_buildtests "" OFF)
add_subdirectory(deps/libuv EXCLUDE_FROM_ALL)
target_link_libraries(tjs PUBLIC uv_a)

if(BUILD_WITH_SQLITE)
    add_subdirectory(deps/sqlite3 EXCLUDE_FROM_ALL)
    target_link_libraries(tjs PUBLIC sqlite3)
    add_library(sqlite-test SHARED
        tests/fixtures/sqlite-test-ext.c
    )
    target_link_libraries(sqlite-test sqlite3)
endif()

if(BUILD_WITH_FFI)
    target_sources(tjs PRIVATE src/mod_ffi.c)
    target_compile_definitions(tjs PRIVATE TJS_HAVE_FFI)
    if (WIN32)
        find_package(unofficial-libffi CONFIG REQUIRED)
        target_link_libraries(tjs PUBLIC unofficial::libffi::libffi)
    else()
        find_library(FFI_LIB NAMES libffi ffi REQUIRED)
        find_path(FFI_INCLUDE_DIR NAMES ffi.h PATH_SUFFIXES ffi REQUIRED)
        target_include_directories(tjs PRIVATE ${FFI_INCLUDE_DIR})
        target_link_libraries(tjs PUBLIC ${FFI_LIB})
    endif()
endif()

add_library(ffi-test SHARED
    tests/fixtures/ffi-test-lib.c
)

# Set consistent output for test libraries across all platforms (including MSVC multi-config)
set(_tjs_test_libs ffi-test)
if(BUILD_WITH_SQLITE)
    list(APPEND _tjs_test_libs sqlite-test)
endif()
set_target_properties(${_tjs_test_libs} PROPERTIES
    PREFIX "lib"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    # For multi-config generators (Visual Studio, Xcode)
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${CMAKE_BINARY_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_DEBUG "${CMAKE_BINARY_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_BINARY_DIR}"
    LIBRARY_OUTPUT_DIRECTORY_MINSIZEREL "${CMAKE_BINARY_DIR}"
)

if(BUILD_WITH_ADA)
    add_subdirectory(deps/ada EXCLUDE_FROM_ALL)
    target_link_libraries(tjs PUBLIC ada)
endif()

if(BUILD_WITH_WASM)
# WAMR Configuration (interpreter only for maximum portability)
set(WAMR_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/deps/wamr)

# Detect platform for WAMR
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(WAMR_BUILD_PLATFORM "darwin")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(WAMR_BUILD_PLATFORM "windows")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Android")
    set(WAMR_BUILD_PLATFORM "android")
else()
    set(WAMR_BUILD_PLATFORM "linux")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND NOT DEFINED WAMR_BUILD_TARGET AND CMAKE_OSX_ARCHITECTURES)
    set(TJS_OSX_ARCHITECTURES ${CMAKE_OSX_ARCHITECTURES})
    list(LENGTH TJS_OSX_ARCHITECTURES TJS_OSX_ARCHITECTURE_COUNT)

    if(TJS_OSX_ARCHITECTURE_COUNT EQUAL 1)
        list(GET TJS_OSX_ARCHITECTURES 0 TJS_OSX_ARCHITECTURE)
        string(TOLOWER "${TJS_OSX_ARCHITECTURE}" TJS_OSX_ARCHITECTURE)

        if(TJS_OSX_ARCHITECTURE MATCHES "^(arm64|aarch64)$")
            set(WAMR_BUILD_TARGET "AARCH64")
        elseif(TJS_OSX_ARCHITECTURE STREQUAL "x86_64")
            set(WAMR_BUILD_TARGET "X86_64")
        endif()
    endif()
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Android" AND NOT DEFINED WAMR_BUILD_TARGET)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(WAMR_BUILD_TARGET "AARCH64")
    elseif(ANDROID_ABI STREQUAL "x86_64")
        set(WAMR_BUILD_TARGET "X86_64")
    endif()
endif()

# Configure WAMR build options
set(WAMR_BUILD_INTERP 1)
set(WAMR_BUILD_FAST_INTERP 1)
set(WAMR_BUILD_AOT 0)
set(WAMR_BUILD_JIT 0)
set(WAMR_BUILD_LIBC_BUILTIN 1)
set(WAMR_BUILD_LIBC_WASI 1)
set(WAMR_BUILD_MULTI_MODULE 1)
set(WAMR_BUILD_SIMD 1)
set(WAMR_BUILD_REF_TYPES 1)
set(WAMR_BUILD_BULK_MEMORY 1)
set(WAMR_BUILD_LIB_PTHREAD 0)
set(WAMR_BUILD_MINI_LOADER 0)
set(WAMR_DISABLE_HW_BOUND_CHECK 1)
set(WAMR_DISABLE_STACK_HW_BOUND_CHECK 1)

# Include WAMR build scripts
include(${WAMR_ROOT_DIR}/build-scripts/runtime_lib.cmake)

add_library(vmlib STATIC ${WAMR_RUNTIME_LIB_SOURCE})
target_include_directories(vmlib PUBLIC ${WAMR_ROOT_DIR}/core/iwasm/include)
if(WIN32)
    target_link_libraries(vmlib PUBLIC ntdll)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    # WAMR's android platform logs via bionic liblog (__android_log_*).
    target_link_libraries(vmlib PUBLIC log)
endif()
target_include_directories(tjs PRIVATE ${WAMR_ROOT_DIR}/core/iwasm/include)
target_link_libraries(tjs PUBLIC vmlib)
endif()

add_subdirectory(deps/miniz EXCLUDE_FROM_ALL)
target_link_libraries(tjs PUBLIC miniz)

option(ENABLE_TESTING "" OFF)
option(ENABLE_PROGRAMS "" OFF)
option(MBEDTLS_FATAL_WARNINGS "" OFF)
set(MBEDTLS_AS_SUBPROJECT ON)
set(MBEDTLS_USER_CONFIG_FILE "${CMAKE_CURRENT_SOURCE_DIR}/src/mbedtls_config.h" CACHE FILEPATH "" FORCE)
set(MSVC_STATIC_RUNTIME ON CACHE BOOL "" FORCE)

# mbedTLS upstream has no QUIC support; patches/mbedtls-quic.patch adds it (from
# warmcat's quic-v3.6.6 mbedTLS branch — credit libwebsockets). Applied to the
# submodule work tree at configure time, idempotently via a forward/reverse
# apply --check.
find_package(Git QUIET)
if(NOT GIT_EXECUTABLE)
    set(GIT_EXECUTABLE git)
endif()
set(MBEDTLS_QUIC_PATCH "${CMAKE_CURRENT_SOURCE_DIR}/patches/mbedtls-quic.patch")
set(MBEDTLS_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps/mbedtls")
execute_process(
    COMMAND "${GIT_EXECUTABLE}" -C "${MBEDTLS_SRC_DIR}" apply --check "${MBEDTLS_QUIC_PATCH}"
    RESULT_VARIABLE MBEDTLS_QUIC_FWD OUTPUT_QUIET ERROR_QUIET)
if(MBEDTLS_QUIC_FWD EQUAL 0)
    message(STATUS "Applying mbedTLS QUIC patch (HTTP/3 support)")
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" -C "${MBEDTLS_SRC_DIR}" apply "${MBEDTLS_QUIC_PATCH}"
        RESULT_VARIABLE MBEDTLS_QUIC_APPLY)
    if(NOT MBEDTLS_QUIC_APPLY EQUAL 0)
        message(FATAL_ERROR "Failed to apply ${MBEDTLS_QUIC_PATCH}")
    endif()
else()
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" -C "${MBEDTLS_SRC_DIR}" apply --reverse --check "${MBEDTLS_QUIC_PATCH}"
        RESULT_VARIABLE MBEDTLS_QUIC_REV OUTPUT_QUIET ERROR_QUIET)
    if(MBEDTLS_QUIC_REV EQUAL 0)
        message(STATUS "mbedTLS QUIC patch already applied")
    else()
        message(FATAL_ERROR "mbedTLS QUIC patch neither applies nor is already applied; "
            "deps/mbedtls is in an unexpected state. Reset it with "
            "'git -C deps/mbedtls checkout .' and reconfigure.")
    endif()
endif()

add_subdirectory(deps/mbedtls EXCLUDE_FROM_ALL)
if(BUILD_WITH_LWS)
    target_link_libraries(tjs PUBLIC mbedtls mbedx509 mbedcrypto)
else()
    # tjs:hashing and optional WebCrypto only need the crypto half; the TLS and
    # X.509 libraries exist solely for lws and tjs:tls.
    target_link_libraries(tjs PUBLIC mbedcrypto)
endif()

if(BUILD_WITH_LWS)
if (NOT CMAKE_BUILD_TYPE MATCHES "Debug")
    set(LWS_WITH_NO_LOGS ON CACHE BOOL "" FORCE)
endif()
set(DISABLE_WERROR ON CACHE BOOL "" FORCE)
set(LWS_WITH_HTTP2 ON CACHE BOOL "" FORCE)
set(LWS_WITH_HTTP3 ON CACHE BOOL "" FORCE)
set(LWS_ROLE_QUIC ON CACHE BOOL "" FORCE)
set(LWS_ROLE_RAW_FILE OFF CACHE BOOL "" FORCE)
set(LWS_UNIX_SOCK OFF CACHE BOOL "" FORCE)
set(LWS_WITH_SYS_STATE OFF CACHE BOOL "" FORCE)
set(LWS_WITH_SYS_SMD OFF CACHE BOOL "" FORCE)
set(LWS_WITH_UPNG OFF CACHE BOOL "" FORCE)
set(LWS_WITH_DLO OFF CACHE BOOL "" FORCE)
set(LWS_WITH_SECURE_STREAMS OFF CACHE BOOL "" FORCE)
set(LWS_WITH_LEJP OFF CACHE BOOL "" FORCE)
set(LWS_WITH_LHP OFF CACHE BOOL "" FORCE)
set(LWS_WITH_JSONRPC OFF CACHE BOOL "" FORCE)
set(LWS_WITH_LWSAC OFF CACHE BOOL "" FORCE)
set(LWS_WITH_CONMON OFF CACHE BOOL "" FORCE)
set(LWS_WITH_WOL OFF CACHE BOOL "" FORCE)
set(LWS_WITH_STUB OFF CACHE BOOL "" FORCE)
# BASIC_AUTH must stay ON: it gates the client-side "Proxy-Authorization:
# basic" header (connect4.c), without which authenticated proxy URLs
# (http_proxy=http://user:pass@host:port) route through the proxy but never
# send credentials.
set(LWS_WITH_HTTP_BASIC_AUTH ON CACHE BOOL "" FORCE)
set(LWS_WITH_HTTP_DIGEST_AUTH OFF CACHE BOOL "" FORCE)
# GENCRYPTO must stay ON: lws compiles tls/lws-gencrypto-common.c (HKDF)
# unconditionally, which needs the genhmac API.
set(LWS_WITH_GENCRYPTO ON CACHE BOOL "" FORCE)
# Note: LWS_WITH_HTTP_UNCOMMON_HEADERS must stay ON: it selects the full
# pre-generated header lexer table; without it headers like
# Transfer-Encoding are not parsed and requests fail with 400.
set(LWS_WITH_JPEG OFF CACHE BOOL "" FORCE)
set(LWS_WITH_GZINFLATE OFF CACHE BOOL "" FORCE)
# Note: LWS_WITH_FILE_OPS must stay ON: lws_create_adopt_udp2 (async DNS)
# needs lws_plat_apply_FD_CLOEXEC from plat/unix/unix-file.c.
set(LWS_WITH_LIBCAP OFF CACHE BOOL "" FORCE)
set(LWS_WITH_BINDTODEVICE OFF CACHE BOOL "" FORCE)
set(LWS_SSL_CLIENT_USE_OS_CA_CERTS OFF CACHE BOOL "" FORCE)
set(LWS_WITH_LIBUV OFF CACHE BOOL "" FORCE)
set(LWS_WITH_MBEDTLS ON CACHE BOOL "" FORCE)
set(LWS_WITH_SSL ON CACHE BOOL "" FORCE)
set(LWS_WITHOUT_EXTENSIONS ON CACHE BOOL "" FORCE)
set(LWS_WITHOUT_TESTAPPS ON CACHE BOOL "" FORCE)
set(LWS_WITH_SHARED OFF CACHE BOOL "" FORCE)
set(LWS_WITH_STATIC ON CACHE BOOL "" FORCE)
set(LWS_MSVC_STATIC_RUNTIME ON CACHE BOOL "" FORCE)
set(LWS_WITH_MINIMAL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LWS_WITH_TLS_SESSIONS OFF CACHE BOOL "" FORCE)
set(LWS_WITH_EXPORT_LWSTARGETS OFF CACHE BOOL "" FORCE)
set(LWS_WITH_NETLINK OFF CACHE BOOL "" FORCE)
# lws's own async DNS resolver discovers nameservers from /etc/resolv.conf
# (generic unix plat) or the net.dnsN system properties (LWS_PLAT_ANDROID).
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    set(LWS_WITH_SYS_ASYNC_DNS OFF CACHE BOOL "" FORCE)
else()
    set(LWS_WITH_SYS_ASYNC_DNS ON CACHE BOOL "" FORCE)
endif()
set(LWS_WITH_SOCKS5 ON CACHE BOOL "" FORCE)
# Our custom event lib (src/lws-evlib.c, event_lib_custom) is a full event-lib
# integration, not lws's built-in poll() loop. LWS_WITH_EVENT_LIBS makes lws
# route every fd/wsi lifecycle event through the event-lib ops — including the
# client connection-pool socket handoff in
# _lws_generic_transaction_completed_active_conn (guarded by this define), which
# is what fetch keep-alive/pipelining relies on to migrate a warm connection to
# the next request. It also disables lws's default-poll() foreign-thread pollfd
# bookkeeping, which is dead code for a custom event lib. Our ops report
# evlib_size_{wsi,vh,ctx} == 0 (watchers live in a wsi-keyed hash map), so no
# per-object evlib storage is expected. LWS_WITH_EVLIB_PLUGINS stays OFF: we
# link one static custom evlib, not runtime-loaded plugins.
set(LWS_WITH_EVENT_LIBS ON CACHE BOOL "" FORCE)
set(LWS_WITH_EVLIB_PLUGINS OFF CACHE BOOL "" FORCE)
set(LWS_WITH_CACHE_NSCOOKIEJAR ON CACHE BOOL "" FORCE)
# Tell lws about mbedtls capabilities (CHECK_FUNCTION_EXISTS fails for static libs)
set(LWS_HAVE_mbedtls_md_setup 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_conf_ciphersuites 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_rsa_complete 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_net_init 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_conf_alpn_protocols 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_get_alpn_protocol 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_conf_sni 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_set_hs_ca_chain 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_set_hs_own_cert 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_set_hs_authmode 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_x509_crt_parse_file 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_internal_aes_encrypt 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_MBEDTLS_NET_SOCKETS 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_MBEDTLS_SSL_NEW_SESSION_TICKET 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_set_quic_transport_ops 1 CACHE BOOL "" FORCE)
set(LWS_HAVE_mbedtls_ssl_set_export_keys_cb 1 CACHE BOOL "" FORCE)
set(LWS_MBEDTLS_LIBRARIES mbedtls mbedx509 mbedcrypto CACHE STRING "" FORCE)
set(LWS_MBEDTLS_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/deps/mbedtls/include" CACHE STRING "" FORCE)
add_subdirectory(deps/libwebsockets EXCLUDE_FROM_ALL)
# Work around mbedtls ssl.h using #if instead of #ifdef on
# MBEDTLS_SSL_DTLS_CONNECTION_ID_COMPAT (undefined when DTLS is disabled).
if(NOT MSVC)
    target_compile_options(websockets PRIVATE -Wno-undef)
endif()
if(CMAKE_C_COMPILER_ID MATCHES "GNU")
    target_compile_options(websockets PRIVATE -Wno-discarded-qualifiers)
endif()
target_link_libraries(tjs PUBLIC websockets)
target_include_directories(tjs PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/deps/libwebsockets/include)
endif()
