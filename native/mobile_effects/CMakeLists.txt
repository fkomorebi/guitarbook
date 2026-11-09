cmake_minimum_required(VERSION 3.22)
project(GuitarbookMobileEffects LANGUAGES C CXX)
# The effect titles/labels in ../effects_host/builtin_effect.h are UTF-8 Chinese
# literals. MSVC would otherwise read them in the system code page (936), which
# breaks the literals (C2001) and mis-encodes them for juce::String::fromUTF8.
if(MSVC)
  add_compile_options(/utf-8)
endif()
include(FetchContent)
# Same pinned archive as the desktop host: fixed tag, verified checksum, one
# shared download cache. The URL stays overridable for mirrored networks.
set(GUITARBOOK_JUCE_TAG "8.0.12")
set(GUITARBOOK_JUCE_SHA256 "dec1a8baee5aaec4502b717a421b850e257ab7e9c2efd03766185ec1957cf102")
set(GUITARBOOK_JUCE_URL
  "https://codeload.github.com/juce-framework/JUCE/tar.gz/refs/tags/${GUITARBOOK_JUCE_TAG}"
  CACHE STRING "JUCE archive URL; override with a mirror when codeload.github.com is unreachable")
set(GUITARBOOK_JUCE_CACHE "${CMAKE_CURRENT_LIST_DIR}/../../.dart_tool/guitarbook-native")
# Reuse an unpacked copy when the cache already holds it, which keeps offline
# Android and desktop test builds working.
if(NOT FETCHCONTENT_SOURCE_DIR_JUCE
   AND EXISTS "${GUITARBOOK_JUCE_CACHE}/JUCE-${GUITARBOOK_JUCE_TAG}/modules/juce_core/juce_core.h")
  set(FETCHCONTENT_SOURCE_DIR_JUCE "${GUITARBOOK_JUCE_CACHE}/JUCE-${GUITARBOOK_JUCE_TAG}"
    CACHE PATH "Local JUCE source directory" FORCE)
  message(STATUS "Using cached JUCE ${GUITARBOOK_JUCE_TAG} from ${FETCHCONTENT_SOURCE_DIR_JUCE}")
endif()
FetchContent_Declare(JUCE
  URL "${GUITARBOOK_JUCE_URL}"
  DOWNLOAD_NAME "JUCE-${GUITARBOOK_JUCE_TAG}.tar.gz"
  DOWNLOAD_DIR "${GUITARBOOK_JUCE_CACHE}/downloads"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  URL_HASH SHA256=${GUITARBOOK_JUCE_SHA256})
FetchContent_MakeAvailable(JUCE)
if(ANDROID)
# JUCE registers its pinned, bundled Oboe 1.9.0 target on Android.
# Reuse it rather than introducing a second target with the same name.
add_library(guitarbook_mobile_effects SHARED android.cpp)
target_compile_features(guitarbook_mobile_effects PRIVATE cxx_std_17)
target_compile_definitions(guitarbook_mobile_effects PRIVATE
  JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0
  JUCE_REPORT_APP_USAGE=0 JUCE_PLUGINHOST_VST3=0 JUCE_PLUGINHOST_AU=0)
target_link_libraries(guitarbook_mobile_effects PRIVATE juce::juce_audio_processors_headless oboe android log)

else()
  add_executable(guitarbook_mobile_effects_test engine_test.cpp)
  target_compile_features(guitarbook_mobile_effects_test PRIVATE cxx_std_17)
  target_compile_definitions(guitarbook_mobile_effects_test PRIVATE JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1 JUCE_USE_CURL=0 JUCE_WEB_BROWSER=0 JUCE_PLUGINHOST_VST3=0 JUCE_PLUGINHOST_AU=0)
  target_link_libraries(guitarbook_mobile_effects_test PRIVATE juce::juce_audio_processors_headless)
  enable_testing()
  add_test(NAME mobile_effects COMMAND guitarbook_mobile_effects_test)
endif()
