cmake_minimum_required(VERSION 3.16)
project(llama_napi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# llama.cpp source -- fetch the pinned commit into this directory:
#   cd entry/src/main/cpp
#   git init llama.cpp && cd llama.cpp
#   git fetch --depth 1 https://github.com/ggml-org/llama.cpp 6184e92c57dcd34de8a3e381d7641a5e75250d5f
#   git checkout FETCH_HEAD
# Pinned because llama.cpp moves fast and this build depends on details of it:
# a newer ggml has already broken the OpenHarmony build once (see
# ohos_compat.h), and napi_llama.cpp calls the llama C API directly. Move the pin
# deliberately, after a build and an on-device embedding check.
# Without the directory the build still succeeds, as a stub with no model
# support; the app then says so on the Generate and Chat screens.
set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp)
set(LLAMA_PINNED_COMMIT 6184e92c57dcd34de8a3e381d7641a5e75250d5f)

if(EXISTS ${LLAMA_DIR}/CMakeLists.txt)
  # Build llama.cpp (and ggml) as static libs, so the NAPI wrapper is the one
  # and only .so produced -- the option is BUILD_SHARED_LIBS in current
  # llama.cpp (LLAMA_STATIC, named here before, does not exist and was
  # silently ignored as an unused cache var).
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build ggml/llama as static libs")
  set(LLAMA_BUILD_TESTS OFF CACHE BOOL "")
  set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "")
  set(LLAMA_BUILD_SERVER OFF CACHE BOOL "")
  set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "")
  set(LLAMA_BUILD_APP OFF CACHE BOOL "")
  # ggml defaults to OpenMP (-fopenmp=libomp) when the toolchain has it, which
  # the OHOS clang's does for compiling -- but libomp.so itself is not part
  # of the device's system libs and is not bundled in the HAP, so the one
  # output .so fails to even load ("Error loading shared library libomp.so"),
  # confirmed on-device this session. ggml's own pthread-based thread pool
  # (used when this is off) needs nothing beyond libc, matching the
  # fully-static, dependency-free .so BUILD_SHARED_LIBS=OFF above is already
  # going for.
  set(GGML_OPENMP OFF CACHE BOOL "Use ggml's own thread pool, not libomp")
  # ggml's own CMakeLists.txt only defines _GNU_SOURCE when
  # CMAKE_SYSTEM_NAME matches "Linux" or "Android" (ggml/src/CMakeLists.txt);
  # the OHOS toolchain sets CMAKE_SYSTEM_NAME to "OHOS", so that guard never
  # fires even though the compiler target (aarch64-linux-ohos, musl libc)
  # does define __linux__ and takes ggml-cpu.c's `#elif defined(__linux__)`
  # affinity-setting branch -- which then fails to compile for want of
  # cpu_set_t/CPU_SET/CPU_ZERO/pthread_setaffinity_np, all of which musl's
  # headers only expose under _GNU_SOURCE. Defined here, before
  # add_subdirectory, so it reaches every target ggml/llama.cpp build below
  # without editing their vendored source.
  add_compile_definitions(_GNU_SOURCE)
  # Current ggml also calls pthread_setaffinity_np, which this libc does not
  # have at all; ohos_compat.h maps it to sched_setaffinity for the calling
  # thread. Forced into C sources only, so nothing else sees the shim.
  add_compile_options($<$<COMPILE_LANGUAGE:C>:-include${CMAKE_CURRENT_SOURCE_DIR}/ohos_compat.h>)
  add_subdirectory(${LLAMA_DIR} llama_build)

  # Which llama.cpp this is, for the warning below and for the app's own
  # build-info string.
  execute_process(COMMAND git -C ${LLAMA_DIR} rev-parse HEAD
    OUTPUT_VARIABLE LLAMA_ACTUAL_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET RESULT_VARIABLE LLAMA_GIT_RESULT)
  if(NOT LLAMA_GIT_RESULT EQUAL 0 OR LLAMA_ACTUAL_COMMIT STREQUAL "")
    set(LLAMA_ACTUAL_COMMIT "unknown")
  endif()
  if(NOT LLAMA_ACTUAL_COMMIT STREQUAL LLAMA_PINNED_COMMIT)
    message(WARNING "llama.cpp at ${LLAMA_ACTUAL_COMMIT}, but this build is pinned to ${LLAMA_PINNED_COMMIT}. "
      "It may not compile for OpenHarmony or may not match napi_llama.cpp; see the comment at the top of this file.")
  endif()

  # NAPI wrapper -- target renamed from "llama" (it collided with llama.cpp's
  # own internal target of the same name, added by add_subdirectory above);
  # OUTPUT_NAME keeps the produced file libllama.so, which is the name
  # LlamaEngine.ets's `import nativeLlama from 'libllama.so'` expects.
  add_library(llama_napi SHARED napi_llama.cpp)
  set_target_properties(llama_napi PROPERTIES OUTPUT_NAME "llama")
  target_compile_definitions(llama_napi PRIVATE VERA_LLAMA_COMMIT="${LLAMA_ACTUAL_COMMIT}")
  target_include_directories(llama_napi PRIVATE
    ${LLAMA_DIR}/include
    ${LLAMA_DIR}/ggml/include
    ${LLAMA_DIR}/common
  )
  target_link_libraries(llama_napi PRIVATE
    llama
    ggml
    libace_napi.z.so
    libhilog_ndk.z.so
  )
else()
  message(WARNING "llama.cpp not found at ${LLAMA_DIR} -- building a stub with no model support. "
    "Embedding search and local generation will be off; see the comment at the top of this file.")
  add_library(llama SHARED napi_llama.cpp)
  target_compile_definitions(llama PRIVATE LLAMA_STUB=1)
  target_link_libraries(llama PRIVATE
    libace_napi.z.so
    libhilog_ndk.z.so
  )
endif()

# USB network (napi_usbnet.cpp): copies packets between UsbNetAbility's VPN and
# the gnirehtet relay on the computer. Needs nothing but libc, so it is built
# whether or not llama.cpp is present.
add_library(usbnet SHARED napi_usbnet.cpp)
target_link_libraries(usbnet PRIVATE
  libace_napi.z.so
  libhilog_ndk.z.so
)
