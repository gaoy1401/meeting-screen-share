#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace meeting {

struct JoinRequest {
  std::string room;
  std::string display_name;
  std::uint32_t session_id = 0;
};

struct SignalingResponse {
  std::string action;
  std::optional<std::string> url;
  std::optional<std::string> token;
  std::optional<std::string> message;
};

std::string buildJoinLine(const JoinRequest& request);
std::string buildLeaveLine();
SignalingResponse parseSignalingResponse(std::string_view json);

}  // namespace meeting
