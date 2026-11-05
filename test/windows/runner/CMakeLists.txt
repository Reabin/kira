cmake_minimum_required(VERSION 3.14)
project(window_state_tests LANGUAGES CXX)

enable_testing()
add_executable(window_state_test
  "window_state_test.cpp"
  "../../../windows/runner/window_state.cpp"
  "../../../windows/runner/win32_window.cpp"
)
target_compile_features(window_state_test PRIVATE cxx_std_17)
target_compile_definitions(window_state_test PRIVATE NOMINMAX UNICODE _UNICODE)
target_compile_options(window_state_test PRIVATE /W4 /WX /utf-8)
target_include_directories(window_state_test PRIVATE
  "../../../windows/flutter/ephemeral"
)
target_link_libraries(window_state_test PRIVATE user32 shell32 ole32 advapi32 dwmapi
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../windows/flutter/ephemeral/flutter_windows.dll.lib"
)
add_custom_command(TARGET window_state_test POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../windows/flutter/ephemeral/flutter_windows.dll"
    "$<TARGET_FILE_DIR:window_state_test>"
)
add_test(NAME window_state_test COMMAND window_state_test)
