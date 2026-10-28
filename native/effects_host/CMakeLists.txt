cmake_minimum_required(VERSION 3.22)
project(GuitarbookEffects VERSION 0.1.0 LANGUAGES C CXX)
# Limit memory use when Flutter invokes Ninja with all available CPU cores.
if(CMAKE_GENERATOR MATCHES "Ninja")
  set_property(GLOBAL APPEND PROPERTY JOB_POOLS guitarbook_effects_compile=2)
  set(CMAKE_JOB_POOL_COMPILE guitarbook_effects_compile)
endif()
# Keep audio/plugin dependencies separate from Flutter and its audio players.
include(FetchContent)
if(NOT TARGET juce::juce_audio_utils)
  FetchContent_Declare(JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG 8.0.12
    GIT_SHALLOW TRUE)
  FetchContent_MakeAvailable(JUCE)
endif()
juce_add_console_app(guitarbook_effects_host PRODUCT_NAME "Guitarbook Effects Host")
target_sources(guitarbook_effects_host PRIVATE main.cpp)
target_compile_features(guitarbook_effects_host PRIVATE cxx_std_17)
target_compile_definitions(guitarbook_effects_host PRIVATE
  JUCE_PLUGINHOST_VST3=1 JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0
  JUCE_REPORT_APP_USAGE=0)
target_link_libraries(guitarbook_effects_host PRIVATE juce::juce_audio_utils
  juce::juce_recommended_config_flags)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  find_path(GUITARBOOK_JACK_INCLUDE_DIR jack/jack.h)
  if(GUITARBOOK_JACK_INCLUDE_DIR)
    target_include_directories(guitarbook_effects_host PRIVATE "${GUITARBOOK_JACK_INCLUDE_DIR}")
    target_compile_definitions(guitarbook_effects_host PRIVATE JUCE_JACK=1 JUCE_JACK_CLIENT_NAME="GuitarbookEffects")
  else()
    message(STATUS "JACK headers unavailable; using ALSA. Install libjack-jackd2-dev to enable JACK.")
  endif()
endif()
# ASIO needs a separately supplied SDK; use WASAPI without that dependency.
install(TARGETS guitarbook_effects_host RUNTIME DESTINATION . COMPONENT Runtime)
install(FILES "${JUCE_SOURCE_DIR}/LICENSE.md"
  DESTINATION data/licenses RENAME JUCE-LICENSE.md COMPONENT Runtime)
install(FILES "${JUCE_SOURCE_DIR}/modules/juce_audio_processors_headless/format_types/VST3_SDK/LICENSE.txt"
  DESTINATION data/licenses RENAME VST3-SDK-LICENSE.txt COMPONENT Runtime)

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
