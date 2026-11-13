#pragma once

#include "meeting/meeting_client.h"

#ifdef _WIN32
#include <windows.h>
#endif

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace meeting {

class MeetingWindow {
 public:
  MeetingWindow();
  ~MeetingWindow();

  bool create(HINSTANCE instance, int show_command);
  int runMessageLoop();

 private:
  static LRESULT CALLBACK windowProcedure(
      HWND window,
      UINT message,
      WPARAM wparam,
      LPARAM lparam);
  LRESULT handleMessage(UINT message, WPARAM wparam, LPARAM lparam);

  void createControls();
  void layoutControls(int width, int height);
  void paint();
  bool ensureVideoBackBuffer(HDC target, int width, int height);
  void destroyVideoBackBuffer();
  void toggleConnection();
  void updateConnected(bool connected);
  void postStatus(std::string status);
  void postParticipantCount(int count);
  void postVideoFrame(RemoteVideoFrame frame);
  void postBoolean(UINT message, bool value);
  std::wstring controlText(HWND control) const;

  HINSTANCE instance_ = nullptr;
  HWND window_ = nullptr;
  HWND server_edit_ = nullptr;
  HWND room_edit_ = nullptr;
  HWND name_edit_ = nullptr;
  HWND join_button_ = nullptr;
  HWND microphone_button_ = nullptr;
  HWND screen_button_ = nullptr;
  HWND participant_label_ = nullptr;
  HWND codec_label_ = nullptr;
  HWND status_label_ = nullptr;
  bool connected_ = false;
  bool microphone_enabled_ = false;
  bool screen_share_enabled_ = false;
  std::unique_ptr<RemoteVideoFrame> video_frame_;
  std::mutex pending_video_mutex_;
  std::optional<RemoteVideoFrame> pending_video_;
  std::atomic<bool> video_message_pending_{false};
  HDC video_back_buffer_dc_ = nullptr;
  HBITMAP video_back_buffer_bitmap_ = nullptr;
  HGDIOBJ video_back_buffer_previous_bitmap_ = nullptr;
  SIZE video_back_buffer_size_{};
  MeetingClient client_;
};

}  // namespace meeting
