#include "meeting/control_protocol.h"

// These checks must run in Release builds too.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <iostream>

int main() {
  const auto join = meeting::buildJoinLine({
      .room = "demo",
      .display_name = "Windows \"测试\"",
      .session_id = 42,
  });
  assert(join.find("\"transport\":\"webrtc\"") != std::string::npos);
  assert(join.find("Windows \\\"测试\\\"") != std::string::npos);
  assert(join.back() == '\n');

  const auto connected = meeting::parseSignalingResponse(
      R"({"action":"webrtc_connect","url":"ws://127.0.0.1:7880","token":"abc.def","room":"demo"})");
  assert(connected.action == "webrtc_connect");
  assert(connected.url == "ws://127.0.0.1:7880");
  assert(connected.token == "abc.def");

  const auto error = meeting::parseSignalingResponse(
      R"({"action":"error","message":"\u65e0\u6cd5\u52a0\u5165"})");
  assert(error.message == "无法加入");

  std::cout << "Windows control protocol checks passed\n";
}
