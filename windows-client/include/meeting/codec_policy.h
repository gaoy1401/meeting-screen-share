#pragma once

#include "livekit/room_event_types.h"

namespace meeting {

// LiveKit FFI protocol values in client-sdk-cpp v1.4.0:
// VP8=0, H264=1, AV1=2, VP9=3, H265=4.
// The public C++ header forward-declares VideoCodec but does not expose named
// enumerators yet, so all numeric use stays isolated in this module.
inline livekit::VideoCodec h264Codec() {
  return static_cast<livekit::VideoCodec>(1);
}

}  // namespace meeting
