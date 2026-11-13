include_guard(GLOBAL)

function(meeting_setup_livekit)
  set(LIVEKIT_SDK_VERSION "1.4.0" CACHE STRING "Pinned LiveKit C++ SDK version")
  set(
    LIVEKIT_LOCAL_SDK_DIR
    ""
    CACHE PATH
    "Extracted LiveKit SDK prefix; skips the release download"
  )

  if(LIVEKIT_LOCAL_SDK_DIR)
    set(_livekit_prefix "${LIVEKIT_LOCAL_SDK_DIR}")
  else()
    if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
      message(FATAL_ERROR "The prebuilt Windows client requires Windows x64.")
    endif()
    set(_asset "livekit-sdk-windows-x64-${LIVEKIT_SDK_VERSION}.zip")
    set(
      _url
      "https://github.com/livekit/client-sdk-cpp/releases/download/v${LIVEKIT_SDK_VERSION}/${_asset}"
    )
    set(_download_dir "${CMAKE_BINARY_DIR}/_downloads")
    set(_sdk_dir "${CMAKE_BINARY_DIR}/_deps/livekit-sdk")
    set(
      _livekit_prefix
      "${_sdk_dir}/livekit-sdk-windows-x64-${LIVEKIT_SDK_VERSION}"
    )
    file(MAKE_DIRECTORY "${_download_dir}" "${_sdk_dir}")
    if(NOT EXISTS "${_livekit_prefix}/lib/cmake/LiveKit/LiveKitConfig.cmake")
      set(_archive "${_download_dir}/${_asset}")
      message(STATUS "Downloading pinned LiveKit C++ SDK ${LIVEKIT_SDK_VERSION}")
      file(
        DOWNLOAD
        "${_url}"
        "${_archive}"
        TLS_VERIFY ON
        SHOW_PROGRESS
        EXPECTED_HASH
        "SHA256=66a1325b35e21c6501ee32f985ba57cf821e0c2aa533a6dff1577c95ff0ccf38"
        STATUS _download_status
      )
      list(GET _download_status 0 _download_code)
      list(GET _download_status 1 _download_message)
      if(NOT _download_code EQUAL 0)
        message(
          FATAL_ERROR
          "LiveKit SDK download failed: ${_download_message}"
        )
      endif()
      file(REMOVE_RECURSE "${_livekit_prefix}")
      file(ARCHIVE_EXTRACT INPUT "${_archive}" DESTINATION "${_sdk_dir}")
    endif()
  endif()

  list(PREPEND CMAKE_PREFIX_PATH "${_livekit_prefix}")
  find_package(LiveKit CONFIG REQUIRED)
  set(MEETING_LIVEKIT_PREFIX "${_livekit_prefix}" PARENT_SCOPE)
endfunction()
