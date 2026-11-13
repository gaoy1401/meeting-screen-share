cmake_minimum_required(VERSION 3.20)
project(MeetingWindowsClient VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "MeetingWindowsClient must be configured on Windows.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(MSVC)
  add_compile_options(/utf-8)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(LiveKitSDK)
meeting_setup_livekit()

add_library(meeting_control_protocol
  src/control_protocol.cpp
)
target_include_directories(
  meeting_control_protocol
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

add_executable(MeetingClient WIN32
  src/main.cpp
  src/meeting_window.cpp
  src/meeting_client.cpp
  src/screen_capturer.cpp
  src/serial_executor.cpp
  src/signaling_client.cpp
)
target_include_directories(
  MeetingClient
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_compile_definitions(
  MeetingClient
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN
)
target_compile_options(MeetingClient PRIVATE /W4 /permissive- /utf-8)
target_link_directories(
  MeetingClient
  PRIVATE "${MEETING_LIVEKIT_PREFIX}/lib"
)
target_link_libraries(
  MeetingClient
  PRIVATE
    meeting_control_protocol
    LiveKit::livekit
    ws2_32
    gdi32
    comctl32
)

foreach(_runtime_dll IN ITEMS livekit.dll livekit_ffi.dll)
  add_custom_command(
    TARGET MeetingClient
    POST_BUILD
    COMMAND
      ${CMAKE_COMMAND} -E copy_if_different
      "${MEETING_LIVEKIT_PREFIX}/bin/${_runtime_dll}"
      "$<TARGET_FILE_DIR:MeetingClient>"
  )
endforeach()

include(CTest)
if(BUILD_TESTING)
  add_executable(
    meeting_control_protocol_test
    tests/control_protocol_test.cpp
  )
  target_link_libraries(
    meeting_control_protocol_test
    PRIVATE meeting_control_protocol
  )
  add_test(
    NAME meeting_control_protocol_test
    COMMAND meeting_control_protocol_test
  )
endif()
