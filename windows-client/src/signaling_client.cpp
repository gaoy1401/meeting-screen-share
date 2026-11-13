#include "meeting/signaling_client.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#endif

#include <array>
#include <charconv>
#include <stdexcept>
#include <string_view>

namespace meeting {
namespace {

#ifdef _WIN32
class WinsockRuntime {
 public:
  WinsockRuntime() {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
      throw std::runtime_error("WSAStartup failed");
    }
  }

  ~WinsockRuntime() { WSACleanup(); }
};

WinsockRuntime& winsockRuntime() {
  static WinsockRuntime runtime;
  return runtime;
}

std::string socketError(const char* operation) {
  return std::string(operation) + " failed, WSA error " +
         std::to_string(WSAGetLastError());
}
#endif

}  // namespace

ServerEndpoint parseServerEndpoint(const std::string& address) {
  std::string_view value(address);
  std::string_view host;
  std::string_view port_text;

  if (!value.empty() && value.front() == '[') {
    const auto closing = value.find(']');
    if (closing == std::string_view::npos || closing + 2 > value.size() ||
        value[closing + 1] != ':') {
      throw std::invalid_argument("IPv6 server must use [host]:port");
    }
    host = value.substr(1, closing - 1);
    port_text = value.substr(closing + 2);
  } else {
    const auto separator = value.rfind(':');
    if (separator == std::string_view::npos) {
      throw std::invalid_argument("server must use host:port");
    }
    host = value.substr(0, separator);
    port_text = value.substr(separator + 1);
  }

  unsigned int port = 0;
  const auto parsed = std::from_chars(
      port_text.data(),
      port_text.data() + port_text.size(),
      port);
  if (host.empty() || parsed.ec != std::errc() ||
      parsed.ptr != port_text.data() + port_text.size() ||
      port == 0 || port > 65535) {
    throw std::invalid_argument("invalid server host or port");
  }
  return {std::string(host), static_cast<std::uint16_t>(port)};
}

SignalingClient::SignalingClient() {
#ifdef _WIN32
  static_cast<void>(winsockRuntime());
#endif
}

SignalingClient::~SignalingClient() {
  disconnect();
}

LiveKitCredentials SignalingClient::join(
    const ServerEndpoint& endpoint,
    const JoinRequest& request) {
  disconnect();
  connectSocket(endpoint);
  sendAll(buildJoinLine(request));

  const auto response = parseSignalingResponse(receiveLine());
  if (response.action == "error") {
    throw std::runtime_error(
        response.message.value_or("meeting server rejected the join request"));
  }
  if (response.action != "webrtc_connect" ||
      !response.url || !response.token) {
    throw std::runtime_error("meeting server returned incomplete WebRTC credentials");
  }
  return {*response.url, *response.token};
}

void SignalingClient::disconnect() {
#ifdef _WIN32
  std::lock_guard lock(mutex_);
  if (socket_ == INVALID_SOCKET) return;
  const std::string leave = buildLeaveLine();
  static_cast<void>(send(socket_, leave.data(), static_cast<int>(leave.size()), 0));
  shutdown(socket_, SD_BOTH);
  closesocket(socket_);
  socket_ = INVALID_SOCKET;
#endif
}

void SignalingClient::connectSocket(const ServerEndpoint& endpoint) {
#ifdef _WIN32
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  addrinfo* results = nullptr;
  const std::string port = std::to_string(endpoint.port);
  if (getaddrinfo(endpoint.host.c_str(), port.c_str(), &hints, &results) != 0) {
    throw std::runtime_error(socketError("getaddrinfo"));
  }

  SOCKET connected = INVALID_SOCKET;
  for (auto* candidate = results; candidate != nullptr;
       candidate = candidate->ai_next) {
    SOCKET current = socket(
        candidate->ai_family,
        candidate->ai_socktype,
        candidate->ai_protocol);
    if (current == INVALID_SOCKET) continue;
    u_long nonblocking = 1;
    ioctlsocket(current, FIONBIO, &nonblocking);
    const int result = connect(
        current,
        candidate->ai_addr,
        static_cast<int>(candidate->ai_addrlen));
    if (result == 0) {
      connected = current;
    } else {
      const int error = WSAGetLastError();
      if (error == WSAEWOULDBLOCK || error == WSAEINPROGRESS ||
          error == WSAEINVAL) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(current, &writable);
        fd_set failed;
        FD_ZERO(&failed);
        FD_SET(current, &failed);
        timeval timeout{.tv_sec = 8, .tv_usec = 0};
        const int selected = select(
            0,
            nullptr,
            &writable,
            &failed,
            &timeout);
        int socket_error = 0;
        int error_size = sizeof(socket_error);
        if (selected > 0 &&
            getsockopt(
                current,
                SOL_SOCKET,
                SO_ERROR,
                reinterpret_cast<char*>(&socket_error),
                &error_size) == 0 &&
            socket_error == 0 &&
            FD_ISSET(current, &writable)) {
          connected = current;
        }
      }
    }
    if (connected != INVALID_SOCKET) {
      u_long blocking = 0;
      ioctlsocket(connected, FIONBIO, &blocking);
      break;
    }
    closesocket(current);
  }
  freeaddrinfo(results);
  if (connected == INVALID_SOCKET) {
    throw std::runtime_error(socketError("connect"));
  }

  BOOL keep_alive = TRUE;
  setsockopt(
      connected,
      SOL_SOCKET,
      SO_KEEPALIVE,
      reinterpret_cast<const char*>(&keep_alive),
      sizeof(keep_alive));
  BOOL no_delay = TRUE;
  setsockopt(
      connected,
      IPPROTO_TCP,
      TCP_NODELAY,
      reinterpret_cast<const char*>(&no_delay),
      sizeof(no_delay));
  DWORD timeout_ms = 10'000;
  setsockopt(
      connected,
      SOL_SOCKET,
      SO_RCVTIMEO,
      reinterpret_cast<const char*>(&timeout_ms),
      sizeof(timeout_ms));
  setsockopt(
      connected,
      SOL_SOCKET,
      SO_SNDTIMEO,
      reinterpret_cast<const char*>(&timeout_ms),
      sizeof(timeout_ms));

  std::lock_guard lock(mutex_);
  socket_ = connected;
#else
  static_cast<void>(endpoint);
  throw std::runtime_error("Windows signaling client used on a non-Windows host");
#endif
}

void SignalingClient::sendAll(const std::string& data) {
#ifdef _WIN32
  std::size_t offset = 0;
  while (offset < data.size()) {
    SOCKET current;
    {
      std::lock_guard lock(mutex_);
      current = socket_;
    }
    if (current == INVALID_SOCKET) {
      throw std::runtime_error("signaling socket is closed");
    }
    const int sent = send(
        current,
        data.data() + offset,
        static_cast<int>(data.size() - offset),
        0);
    if (sent == SOCKET_ERROR || sent == 0) {
      throw std::runtime_error(socketError("send"));
    }
    offset += static_cast<std::size_t>(sent);
  }
#else
  static_cast<void>(data);
#endif
}

std::string SignalingClient::receiveLine() {
#ifdef _WIN32
  std::string buffer;
  buffer.reserve(1024);
  std::array<char, 1024> chunk{};
  while (buffer.size() <= 4096) {
    SOCKET current;
    {
      std::lock_guard lock(mutex_);
      current = socket_;
    }
    if (current == INVALID_SOCKET) {
      throw std::runtime_error("signaling socket is closed");
    }
    const int received = recv(
        current,
        chunk.data(),
        static_cast<int>(chunk.size()),
        0);
    if (received == SOCKET_ERROR) {
      throw std::runtime_error(socketError("recv"));
    }
    if (received == 0) {
      throw std::runtime_error("meeting server closed signaling connection");
    }
    buffer.append(chunk.data(), static_cast<std::size_t>(received));
    const auto newline = buffer.find('\n');
    if (newline != std::string::npos) {
      return buffer.substr(0, newline);
    }
  }
  throw std::runtime_error("signaling response exceeds 4096 bytes");
#else
  throw std::runtime_error("Windows signaling client used on a non-Windows host");
#endif
}

}  // namespace meeting
