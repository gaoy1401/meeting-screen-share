#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

namespace livekit {
class VideoSource;
}

namespace meeting {

class ScreenCapturer {
 public:
  using ErrorCallback = std::function<void(std::string)>;

  ScreenCapturer(int width, int height, int frames_per_second);
  ~ScreenCapturer();

  ScreenCapturer(const ScreenCapturer&) = delete;
  ScreenCapturer& operator=(const ScreenCapturer&) = delete;

  void start(
      std::shared_ptr<livekit::VideoSource> source,
      ErrorCallback on_error);
  void stop();
  bool running() const noexcept { return running_.load(); }

 private:
  void captureLoop(
      std::shared_ptr<livekit::VideoSource> source,
      ErrorCallback on_error);

  int width_;
  int height_;
  int frames_per_second_;
  std::atomic<bool> running_{false};
  std::thread thread_;
};

}  // namespace meeting
