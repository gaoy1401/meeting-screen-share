#include "meeting/screen_capturer.h"

#ifdef _WIN32
#include <windows.h>
#endif

#include "livekit/livekit.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <stdexcept>
#include <utility>

namespace meeting {

ScreenCapturer::ScreenCapturer(
    int width,
    int height,
    int frames_per_second)
    : width_(width),
      height_(height),
      frames_per_second_(frames_per_second) {
  if (width <= 0 || height <= 0 || frames_per_second <= 0) {
    throw std::invalid_argument("invalid screen capture dimensions or frame rate");
  }
}

ScreenCapturer::~ScreenCapturer() {
  stop();
}

void ScreenCapturer::start(
    std::shared_ptr<livekit::VideoSource> source,
    ErrorCallback on_error) {
  if (!source) throw std::invalid_argument("screen video source is required");
  if (running_.exchange(true)) return;
  thread_ = std::thread(
      [this, source = std::move(source), on_error = std::move(on_error)] {
        captureLoop(source, on_error);
      });
}

void ScreenCapturer::stop() {
  running_.store(false);
  if (thread_.joinable()) thread_.join();
}

void ScreenCapturer::captureLoop(
    std::shared_ptr<livekit::VideoSource> source,
    ErrorCallback on_error) {
#ifdef _WIN32
  HDC screen_dc = nullptr;
  HDC target_dc = nullptr;
  HBITMAP bitmap = nullptr;
  HGDIOBJ previous_bitmap = nullptr;
  void* pixels = nullptr;

  const auto cleanup = [&] {
    if (target_dc && previous_bitmap) {
      SelectObject(target_dc, previous_bitmap);
    }
    if (bitmap) DeleteObject(bitmap);
    if (target_dc) DeleteDC(target_dc);
    if (screen_dc) ReleaseDC(nullptr, screen_dc);
  };

  try {
    screen_dc = GetDC(nullptr);
    if (!screen_dc) throw std::runtime_error("GetDC failed");
    target_dc = CreateCompatibleDC(screen_dc);
    if (!target_dc) throw std::runtime_error("CreateCompatibleDC failed");

    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = width_;
    bitmap_info.bmiHeader.biHeight = -height_;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    bitmap = CreateDIBSection(
        target_dc,
        &bitmap_info,
        DIB_RGB_COLORS,
        &pixels,
        nullptr,
        0);
    if (!bitmap || !pixels) throw std::runtime_error("CreateDIBSection failed");
    previous_bitmap = SelectObject(target_dc, bitmap);
    if (!previous_bitmap || previous_bitmap == HGDI_ERROR) {
      previous_bitmap = nullptr;
      throw std::runtime_error("SelectObject failed");
    }
    SetStretchBltMode(target_dc, HALFTONE);
    SetBrushOrgEx(target_dc, 0, 0, nullptr);

    const int source_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int source_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int source_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    const int source_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (source_width <= 0 || source_height <= 0) {
      throw std::runtime_error("Windows returned invalid desktop dimensions");
    }

    const double scale = std::min(
        static_cast<double>(width_) / source_width,
        static_cast<double>(height_) / source_height);
    const int output_width =
        std::max(1, static_cast<int>(source_width * scale));
    const int output_height =
        std::max(1, static_cast<int>(source_height * scale));
    const int output_x = (width_ - output_width) / 2;
    const int output_y = (height_ - output_height) / 2;

    const auto frame_interval =
        std::chrono::microseconds(1'000'000 / frames_per_second_);
    auto deadline = std::chrono::steady_clock::now();
    while (running_.load()) {
      PatBlt(target_dc, 0, 0, width_, height_, BLACKNESS);
      if (!StretchBlt(
              target_dc,
              output_x,
              output_y,
              output_width,
              output_height,
              screen_dc,
              source_x,
              source_y,
              source_width,
              source_height,
              SRCCOPY | CAPTUREBLT)) {
        throw std::runtime_error("StretchBlt screen capture failed");
      }

      auto frame = livekit::VideoFrame::create(
          width_,
          height_,
          livekit::VideoBufferType::BGRA);
      auto* pixel_bytes = static_cast<std::uint8_t*>(pixels);
      for (std::size_t index = 3; index < frame.dataSize(); index += 4) {
        pixel_bytes[index] = 0xff;
      }
      std::memcpy(frame.data(), pixels, frame.dataSize());
      livekit::VideoCaptureOptions options;
      options.timestamp_us = std::chrono::duration_cast<std::chrono::microseconds>(
                                 std::chrono::steady_clock::now()
                                     .time_since_epoch())
                                 .count();
      source->captureFrame(frame, options);

      deadline += frame_interval;
      std::this_thread::sleep_until(deadline);
      const auto now = std::chrono::steady_clock::now();
      if (deadline + frame_interval < now) deadline = now;
    }
  } catch (const std::exception& error) {
    running_.store(false);
    if (on_error) on_error(error.what());
  }
  cleanup();
#else
  static_cast<void>(source);
  running_.store(false);
  if (on_error) on_error("Windows screen capturer used on a non-Windows host");
#endif
}

}  // namespace meeting
