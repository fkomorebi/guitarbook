cmake_minimum_required(VERSION 3.22)
project(GuitarbookMobileEffects LANGUAGES C CXX)
include(FetchContent)
FetchContent_Declare(JUCE
  URL https://codeload.github.com/juce-framework/JUCE/tar.gz/refs/tags/8.0.12
  DOWNLOAD_NAME JUCE-8.0.12.tar.gz
  DOWNLOAD_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.dart_tool/guitarbook-native/downloads"
  URL_HASH SHA256=dec1a8baee5aaec4502b717a421b850e257ab7e9c2efd03766185ec1957cf102)
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
