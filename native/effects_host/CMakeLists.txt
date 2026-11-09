cmake_minimum_required(VERSION 3.22)
project(GuitarbookEffects VERSION 0.1.0 LANGUAGES C CXX)
# Limit memory use when Flutter invokes Ninja with all available CPU cores.
if(CMAKE_GENERATOR MATCHES "Ninja")
  set_property(GLOBAL APPEND PROPERTY JOB_POOLS guitarbook_effects_compile=2)
  set(CMAKE_JOB_POOL_COMPILE guitarbook_effects_compile)
endif()
# MSVC reads source files in the system code page unless told otherwise. The
# Chinese literals in builtin_effect.h/main.cpp are UTF-8, so a GBK (936) read
# swallows the closing quote of a string literal and the compiler reports C2001
# "newline in string literal". /utf-8 also keeps narrow literals UTF-8, which
# the juce::String::fromUTF8 calls and the UTF-8 stdout protocol expect.
# Set before JUCE is added so the JUCE targets inherit it as well.
if(MSVC)
  add_compile_options(/utf-8)
endif()
# Keep audio/plugin dependencies separate from Flutter and its audio players.
include(FetchContent)
if(NOT TARGET juce::juce_audio_utils)
  # Fetch the pinned JUCE release as a checksum-verified source archive instead
  # of a git clone: no git network access is needed, and the archive is the
  # same one the mobile backend already builds against.
  set(GUITARBOOK_JUCE_TAG "8.0.12")
  set(GUITARBOOK_JUCE_SHA256 "dec1a8baee5aaec4502b717a421b850e257ab7e9c2efd03766185ec1957cf102")
  set(GUITARBOOK_JUCE_URL
    "https://codeload.github.com/juce-framework/JUCE/tar.gz/refs/tags/${GUITARBOOK_JUCE_TAG}"
    CACHE STRING "JUCE archive URL; override with a mirror when codeload.github.com is unreachable")
  set(GUITARBOOK_JUCE_CACHE "${CMAKE_CURRENT_LIST_DIR}/../../.dart_tool/guitarbook-native")
  # Reuse an unpacked copy when the cache already holds it, so repeated and
  # offline builds never touch the network.
  if(NOT FETCHCONTENT_SOURCE_DIR_JUCE
     AND EXISTS "${GUITARBOOK_JUCE_CACHE}/JUCE-${GUITARBOOK_JUCE_TAG}/modules/juce_core/juce_core.h")
    set(FETCHCONTENT_SOURCE_DIR_JUCE "${GUITARBOOK_JUCE_CACHE}/JUCE-${GUITARBOOK_JUCE_TAG}"
      CACHE PATH "Local JUCE source directory" FORCE)
    message(STATUS "Using cached JUCE ${GUITARBOOK_JUCE_TAG} from ${FETCHCONTENT_SOURCE_DIR_JUCE}")
  else()
    message(STATUS "Downloading JUCE ${GUITARBOOK_JUCE_TAG} into ${GUITARBOOK_JUCE_CACHE}/downloads")
    message(STATUS "Behind a proxy or an offline mirror? Run tool/prepare_juce_sources.ps1 once, "
                   "or configure with -DGUITARBOOK_JUCE_URL=<mirror url>")
  endif()
  FetchContent_Declare(JUCE
    URL "${GUITARBOOK_JUCE_URL}"
    DOWNLOAD_NAME "JUCE-${GUITARBOOK_JUCE_TAG}.tar.gz"
    DOWNLOAD_DIR "${GUITARBOOK_JUCE_CACHE}/downloads"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    URL_HASH SHA256=${GUITARBOOK_JUCE_SHA256})
  FetchContent_MakeAvailable(JUCE)
endif()
# VST2 support is optional. JUCE 8 does not ship the VST2 SDK headers any
# more, so a build that wants to load VST2 plugins needs the Steinberg VST2
# SDK. The SDK is never copied into this repository, the developer points the
# build at an existing installation of it.
option(GUITARBOOK_ENABLE_VST2 "Build the host with VST2 support (needs the Steinberg VST2 SDK)" OFF)
set(GUITARBOOK_VST2_SDK_DIR "" CACHE PATH
  "Steinberg VST2 SDK directory; must contain pluginterfaces/vst2.x/aeffect.h")
if(GUITARBOOK_ENABLE_VST2)
  if(NOT GUITARBOOK_VST2_SDK_DIR)
    message(FATAL_ERROR
      "GUITARBOOK_ENABLE_VST2 needs GUITARBOOK_VST2_SDK_DIR to point at the Steinberg VST2 SDK.")
  endif()
  if(NOT EXISTS "${GUITARBOOK_VST2_SDK_DIR}/pluginterfaces/vst2.x/aeffect.h")
    message(FATAL_ERROR
      "The Steinberg VST2 SDK was not found in ${GUITARBOOK_VST2_SDK_DIR}: pluginterfaces/vst2.x/aeffect.h is missing.")
  endif()
  message(STATUS "VST2 support enabled with the SDK from ${GUITARBOOK_VST2_SDK_DIR}")
endif()
juce_add_console_app(guitarbook_effects_host PRODUCT_NAME "Guitarbook Effects Host")
target_sources(guitarbook_effects_host PRIVATE main.cpp plugin_scanner.cpp)
target_compile_features(guitarbook_effects_host PRIVATE cxx_std_17)
target_compile_definitions(guitarbook_effects_host PRIVATE
  JUCE_PLUGINHOST_VST3=1 JUCE_PLUGINHOST_VST=$<BOOL:${GUITARBOOK_ENABLE_VST2}>
  GUITARBOOK_VST2_ENABLED=$<BOOL:${GUITARBOOK_ENABLE_VST2}>
  JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0
  JUCE_REPORT_APP_USAGE=0)
target_link_libraries(guitarbook_effects_host PRIVATE juce::juce_audio_utils
  juce::juce_recommended_config_flags)
if(GUITARBOOK_ENABLE_VST2)
  # JUCE includes <pluginterfaces/vst2.x/aeffect.h> from the SDK directory.
  target_include_directories(guitarbook_effects_host PRIVATE "${GUITARBOOK_VST2_SDK_DIR}")
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  find_path(GUITARBOOK_JACK_INCLUDE_DIR jack/jack.h)
  if(GUITARBOOK_JACK_INCLUDE_DIR)
    target_include_directories(guitarbook_effects_host PRIVATE "${GUITARBOOK_JACK_INCLUDE_DIR}")
    target_compile_definitions(guitarbook_effects_host PRIVATE JUCE_JACK=1 JUCE_JACK_CLIENT_NAME="GuitarbookEffects")
  else()
    message(STATUS "JACK headers unavailable; using ALSA. Install libjack-jackd2-dev to enable JACK.")
  endif()
endif()
# Windows: offer the user's own ASIO driver in the device selector, which is
# the low-latency path on Windows. JUCE 8 ships the ASIO SDK interface headers
# it needs, so no separate SDK download is required; the Steinberg ASIO SDK
# licence covers the shipped build and is installed next to the host.
if(WIN32)
  target_compile_definitions(guitarbook_effects_host PRIVATE JUCE_ASIO=1)
  # The plugin scan reads the version resources of the VST2 modules and the
  # Steinberg registry keys that list the installed VST2 plugins.
  target_link_libraries(guitarbook_effects_host PRIVATE version advapi32)
endif()
# The Flutter app starts the host from the directory of its own executable, so
# the host has to be installed into the app bundle. The bundle directory is a
# generator expression, and CMake only expands generator expressions in
# absolute install destinations, so the absolute bundle directory is passed in
# by windows/CMakeLists.txt.
if(GUITARBOOK_EFFECTS_HOST_BUNDLE_DIR)
  set(GUITARBOOK_EFFECTS_HOST_INSTALL_DIR "${GUITARBOOK_EFFECTS_HOST_BUNDLE_DIR}")
else()
  set(GUITARBOOK_EFFECTS_HOST_INSTALL_DIR ".")
endif()
install(TARGETS guitarbook_effects_host RUNTIME DESTINATION "${GUITARBOOK_EFFECTS_HOST_INSTALL_DIR}" COMPONENT Runtime)
install(FILES "${JUCE_SOURCE_DIR}/LICENSE.md"
  DESTINATION "${GUITARBOOK_EFFECTS_HOST_INSTALL_DIR}/data/licenses" RENAME JUCE-LICENSE.md COMPONENT Runtime)
install(FILES "${JUCE_SOURCE_DIR}/modules/juce_audio_processors_headless/format_types/VST3_SDK/LICENSE.txt"
  DESTINATION "${GUITARBOOK_EFFECTS_HOST_INSTALL_DIR}/data/licenses" RENAME VST3-SDK-LICENSE.txt COMPONENT Runtime)
if(WIN32)
  # JUCE's ASIO backend compiles the Steinberg ASIO SDK interface headers, so
  # the SDK licence ships with the app.
  install(FILES "${JUCE_SOURCE_DIR}/modules/juce_audio_devices/native/asio/LICENSE.txt"
    DESTINATION "${GUITARBOOK_EFFECTS_HOST_INSTALL_DIR}/data/licenses" RENAME ASIO-SDK-LICENSE.txt COMPONENT Runtime)
endif()

option(GUITARBOOK_EFFECTS_TESTS "Build the offline VST3 integration fixture" OFF)
if(GUITARBOOK_EFFECTS_TESTS)
  juce_add_plugin(guitarbook_test_gain
    COMPANY_NAME Guitarbook PLUGIN_MANUFACTURER_CODE Gtbk PLUGIN_CODE Gtgn
    FORMATS VST3 PRODUCT_NAME "Guitarbook Test Gain"
    IS_SYNTH FALSE NEEDS_MIDI_INPUT FALSE NEEDS_MIDI_OUTPUT FALSE)
  target_sources(guitarbook_test_gain PRIVATE test_gain.cpp)
  target_compile_definitions(guitarbook_test_gain PRIVATE
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0 JUCE_VST3_CAN_REPLACE_VST2=0)
  target_link_libraries(guitarbook_test_gain PRIVATE juce::juce_audio_utils)
  target_compile_features(guitarbook_test_gain PRIVATE cxx_std_17)
endif()
