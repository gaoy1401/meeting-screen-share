#pragma once

#include "meeting/control_protocol.h"

#include <cstdint>
#include <mutex>
#include <string>

#ifdef _WIN32
#include <winsock2.h>
#else
using SOCKET = std::uintptr_t;
constexpr SOCKET INVALID_SOCKET = static_cast<SOCKET>(~0U);
#endif

namespace meeting {

struct ServerEndpoint {
  std::string host;
  std::uint16_t port = 0;
};

struct LiveKitCredentials {
  std::string url;
  std::string token;
};

ServerEndpoint parseServerEndpoint(const std::string& address);

class SignalingClient {
 public:
  SignalingClient();
  ~SignalingClient();

  SignalingClient(const SignalingClient&) = delete;
  SignalingClient& operator=(const SignalingClient&) = delete;

  LiveKitCredentials join(
      const ServerEndpoint& endpoint,
      const JoinRequest& request);
  void disconnect();

 private:
  void connectSocket(const ServerEndpoint& endpoint);
  void sendAll(const std::string& data);
  std::string receiveLine();

  std::mutex mutex_;
  SOCKET socket_ = INVALID_SOCKET;
};

}  // namespace meeting
