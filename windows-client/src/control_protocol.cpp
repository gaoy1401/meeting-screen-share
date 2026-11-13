#include "meeting/control_protocol.h"

#include <charconv>
#include <stdexcept>

namespace meeting {
namespace {

std::string escapeJson(std::string_view input) {
  std::string output;
  output.reserve(input.size() + 8);
  constexpr char hex[] = "0123456789abcdef";
  for (const unsigned char byte : input) {
    switch (byte) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\b':
        output += "\\b";
        break;
      case '\f':
        output += "\\f";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (byte < 0x20) {
          output += "\\u00";
          output.push_back(hex[(byte >> 4) & 0x0f]);
          output.push_back(hex[byte & 0x0f]);
        } else {
          output.push_back(static_cast<char>(byte));
        }
    }
  }
  return output;
}

void appendUtf8(std::string& output, std::uint32_t code_point) {
  if (code_point <= 0x7f) {
    output.push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7ff) {
    output.push_back(static_cast<char>(0xc0 | (code_point >> 6)));
    output.push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  } else if (code_point <= 0xffff) {
    output.push_back(static_cast<char>(0xe0 | (code_point >> 12)));
    output.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  } else if (code_point <= 0x10ffff) {
    output.push_back(static_cast<char>(0xf0 | (code_point >> 18)));
    output.push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (code_point & 0x3f)));
  } else {
    throw std::runtime_error("invalid JSON Unicode code point");
  }
}

class JsonReader {
 public:
  explicit JsonReader(std::string_view input) : input_(input) {}

  SignalingResponse parseResponse() {
    SignalingResponse response;
    skipWhitespace();
    expect('{');
    skipWhitespace();
    if (consume('}')) {
      throw std::runtime_error("signaling response has no action");
    }

    while (true) {
      const std::string key = parseString();
      skipWhitespace();
      expect(':');
      skipWhitespace();
      if (peek() == '"') {
        const std::string value = parseString();
        if (key == "action") response.action = value;
        if (key == "url") response.url = value;
        if (key == "token") response.token = value;
        if (key == "message") response.message = value;
      } else {
        skipValue();
      }
      skipWhitespace();
      if (consume('}')) break;
      expect(',');
      skipWhitespace();
    }
    skipWhitespace();
    if (position_ != input_.size()) {
      throw std::runtime_error("trailing data after signaling response");
    }
    if (response.action.empty()) {
      throw std::runtime_error("signaling response has no action");
    }
    return response;
  }

 private:
  char peek() const {
    if (position_ >= input_.size()) {
      throw std::runtime_error("unexpected end of JSON");
    }
    return input_[position_];
  }

  bool consume(char expected) {
    if (position_ < input_.size() && input_[position_] == expected) {
      ++position_;
      return true;
    }
    return false;
  }

  void expect(char expected) {
    if (!consume(expected)) {
      throw std::runtime_error("invalid signaling JSON");
    }
  }

  void skipWhitespace() {
    while (position_ < input_.size()) {
      const char value = input_[position_];
      if (value != ' ' && value != '\n' && value != '\r' && value != '\t') break;
      ++position_;
    }
  }

  static std::uint32_t hexValue(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    throw std::runtime_error("invalid JSON Unicode escape");
  }

  std::uint32_t parseHex4() {
    if (position_ + 4 > input_.size()) {
      throw std::runtime_error("short JSON Unicode escape");
    }
    std::uint32_t value = 0;
    for (int index = 0; index < 4; ++index) {
      value = (value << 4) | hexValue(input_[position_++]);
    }
    return value;
  }

  std::string parseString() {
    expect('"');
    std::string output;
    while (position_ < input_.size()) {
      const unsigned char value = input_[position_++];
      if (value == '"') return output;
      if (value < 0x20) throw std::runtime_error("control character in JSON string");
      if (value != '\\') {
        output.push_back(static_cast<char>(value));
        continue;
      }
      if (position_ >= input_.size()) throw std::runtime_error("short JSON escape");
      switch (input_[position_++]) {
        case '"':
          output.push_back('"');
          break;
        case '\\':
          output.push_back('\\');
          break;
        case '/':
          output.push_back('/');
          break;
        case 'b':
          output.push_back('\b');
          break;
        case 'f':
          output.push_back('\f');
          break;
        case 'n':
          output.push_back('\n');
          break;
        case 'r':
          output.push_back('\r');
          break;
        case 't':
          output.push_back('\t');
          break;
        case 'u': {
          std::uint32_t code_point = parseHex4();
          if (code_point >= 0xd800 && code_point <= 0xdbff) {
            if (position_ + 2 > input_.size() || input_[position_] != '\\' ||
                input_[position_ + 1] != 'u') {
              throw std::runtime_error("missing low Unicode surrogate");
            }
            position_ += 2;
            const std::uint32_t low = parseHex4();
            if (low < 0xdc00 || low > 0xdfff) {
              throw std::runtime_error("invalid low Unicode surrogate");
            }
            code_point = 0x10000 + ((code_point - 0xd800) << 10) + (low - 0xdc00);
          } else if (code_point >= 0xdc00 && code_point <= 0xdfff) {
            throw std::runtime_error("unexpected low Unicode surrogate");
          }
          appendUtf8(output, code_point);
          break;
        }
        default:
          throw std::runtime_error("unsupported JSON escape");
      }
    }
    throw std::runtime_error("unterminated JSON string");
  }

  void skipValue() {
    if (peek() == '"') {
      static_cast<void>(parseString());
      return;
    }
    int object_depth = 0;
    int array_depth = 0;
    while (position_ < input_.size()) {
      const char value = input_[position_];
      if (value == '"') {
        static_cast<void>(parseString());
        continue;
      }
      if (value == '{') ++object_depth;
      if (value == '}') {
        if (object_depth == 0 && array_depth == 0) return;
        --object_depth;
      }
      if (value == '[') ++array_depth;
      if (value == ']') --array_depth;
      if (value == ',' && object_depth == 0 && array_depth == 0) return;
      ++position_;
    }
  }

  std::string_view input_;
  std::size_t position_ = 0;
};

}  // namespace

std::string buildJoinLine(const JoinRequest& request) {
  if (request.room.size() < 2 || request.room.size() > 64) {
    throw std::invalid_argument("room length must be 2-64 bytes");
  }
  if (request.display_name.empty()) {
    throw std::invalid_argument("display name is required");
  }
  if (request.session_id == 0) {
    throw std::invalid_argument("session ID must be non-zero");
  }

  return "{\"action\":\"join\",\"room\":\"" + escapeJson(request.room) +
         "\",\"name\":\"" + escapeJson(request.display_name) +
         "\",\"sessionId\":" + std::to_string(request.session_id) +
         ",\"transport\":\"webrtc\"}\n";
}

std::string buildLeaveLine() {
  return "{\"action\":\"leave\"}\n";
}

SignalingResponse parseSignalingResponse(std::string_view json) {
  return JsonReader(json).parseResponse();
}

}  // namespace meeting
