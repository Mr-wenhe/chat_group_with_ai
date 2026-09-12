# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(chat_group LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "chat_group")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
#
# desktop_webview_window 0.3.0 embeds a Flutter title-bar view inside the
# native WebView window. Its top-level message handler can consume the
# system WM_CLOSE message before the host window reaches DefWindowProc, so
# clicking the native close button appears to do nothing. Patch the pinned
# plugin source at configure time and handle WM_CLOSE before delegating to
# the embedded Flutter view. WM_DESTROY then emits the plugin's normal
# onWindowClose callback, allowing the Dart session lifecycle to update.
set(DESKTOP_WEBVIEW_WINDOW_SOURCE
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/desktop_webview_window/windows/webview_window.cc")
if(NOT EXISTS "${DESKTOP_WEBVIEW_WINDOW_SOURCE}")
  message(FATAL_ERROR
    "desktop_webview_window native source not found: ${DESKTOP_WEBVIEW_WINDOW_SOURCE}")
endif()
file(READ "${DESKTOP_WEBVIEW_WINDOW_SOURCE}" DESKTOP_WEBVIEW_WINDOW_CODE)
set(DESKTOP_WEBVIEW_WINDOW_CLOSE_MARKER
  "  // Give Flutter, including plugins, an opportunity to handle window messages.\n")
set(DESKTOP_WEBVIEW_WINDOW_CLOSE_GUARD
  "  // Process the native close button before the embedded Flutter view can\n  // consume WM_CLOSE. WM_DESTROY emits onWindowClose to Dart.\n  if (message == WM_CLOSE ||\n      (message == WM_SYSCOMMAND && (wparam & 0xFFF0) == SC_CLOSE)) {\n    DestroyWindow(hwnd);\n    return 0;\n  }\n\n  // Give Flutter, including plugins, an opportunity to handle window messages.\n")
if(DESKTOP_WEBVIEW_WINDOW_CODE MATCHES "SC_CLOSE")
  # The guard is already present; keep configuration idempotent.
elseif(DESKTOP_WEBVIEW_WINDOW_CODE MATCHES "WM_CLOSE")
  # Expand an earlier version of this patch to cover the system command that
  # normally precedes WM_CLOSE when the user clicks the native close button.
  set(DESKTOP_WEBVIEW_WINDOW_CLOSE_OLD
    "  if (message == WM_CLOSE) {\n    DestroyWindow(hwnd);\n    return 0;\n  }\n")
  set(DESKTOP_WEBVIEW_WINDOW_CLOSE_NEW
    "  if (message == WM_CLOSE ||\n      (message == WM_SYSCOMMAND && (wparam & 0xFFF0) == SC_CLOSE)) {\n    DestroyWindow(hwnd);\n    return 0;\n  }\n")
  string(REPLACE
    "${DESKTOP_WEBVIEW_WINDOW_CLOSE_OLD}"
    "${DESKTOP_WEBVIEW_WINDOW_CLOSE_NEW}"
    DESKTOP_WEBVIEW_WINDOW_CODE
    "${DESKTOP_WEBVIEW_WINDOW_CODE}")
  file(WRITE "${DESKTOP_WEBVIEW_WINDOW_SOURCE}" "${DESKTOP_WEBVIEW_WINDOW_CODE}")
elseif(DESKTOP_WEBVIEW_WINDOW_CODE MATCHES "Give Flutter, including plugins")
  string(REPLACE
    "${DESKTOP_WEBVIEW_WINDOW_CLOSE_MARKER}"
    "${DESKTOP_WEBVIEW_WINDOW_CLOSE_GUARD}"
    DESKTOP_WEBVIEW_WINDOW_CODE
    "${DESKTOP_WEBVIEW_WINDOW_CODE}")
  file(WRITE "${DESKTOP_WEBVIEW_WINDOW_SOURCE}" "${DESKTOP_WEBVIEW_WINDOW_CODE}")
else()
  message(FATAL_ERROR
    "desktop_webview_window MessageHandler marker not found: ${DESKTOP_WEBVIEW_WINDOW_SOURCE}")
endif()

include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
