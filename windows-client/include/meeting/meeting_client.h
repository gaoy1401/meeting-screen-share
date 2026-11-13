#pragma once

#include "meeting/screen_capturer.h"
#include "meeting/serial_executor.h"
#include "meeting/signaling_client.h"

#include "livekit/livekit.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace meeting {

struct RemoteVideoFrame {
  int width = 0;
  int height = 0;
  std::vector<std::uint8_t> bgra;
};

struct MeetingCallbacks {
  std::function<void(std::string)> on_status;
  std::function<void(int)> on_participant_count;
  std::function<void(RemoteVideoFrame)> on_video_frame;
  std::function<void(bool)> on_connected;
  std::function<void(bool)> on_microphone_changed;
  std::function<void(bool)> on_screen_share_changed;
};

class MeetingClient final : public livekit::RoomDelegate {
 public:
  explicit MeetingClient(MeetingCallbacks callbacks);
  ~MeetingClient() override;

  MeetingClient(const MeetingClient&) = delete;
  MeetingClient& operator=(const MeetingClient&) = delete;

  void connect(
      std::string server_address,
      std::string room,
      std::string display_name);
  void disconnect();
  void setMicrophoneEnabled(bool enabled);
  void setScreenShareEnabled(bool enabled);

  void onParticipantConnected(
      livekit::Room& room,
      const livekit::ParticipantConnectedEvent& event) override;
  void onParticipantDisconnected(
      livekit::Room& room,
      const livekit::ParticipantDisconnectedEvent& event) override;
  void onTrackSubscribed(
      livekit::Room& room,
      const livekit::TrackSubscribedEvent& event) override;
  void onTrackUnsubscribed(
      livekit::Room& room,
      const livekit::TrackUnsubscribedEvent& event) override;
  void onReconnecting(
      livekit::Room& room,
      const livekit::ReconnectingEvent& event) override;
  void onReconnected(
      livekit::Room& room,
      const livekit::ReconnectedEvent& event) override;
  void onDisconnected(
      livekit::Room& room,
      const livekit::DisconnectedEvent& event) override;

 private:
  void connectImpl(
      const std::string& server_address,
      const std::string& room,
      const std::string& display_name);
  void disconnectImpl(bool report_status);
  void setMicrophoneImpl(bool enabled);
  void setScreenShareImpl(bool enabled);
  void ensurePlatformAudio();
  void emitParticipantCount(livekit::Room& room);
  void emitStatus(std::string message) const;

  MeetingCallbacks callbacks_;
  SerialExecutor executor_;
  SignalingClient signaling_;
  std::unique_ptr<livekit::Room> room_;
  std::unique_ptr<livekit::PlatformAudio> platform_audio_;
  std::shared_ptr<livekit::PlatformAudioSource> microphone_source_;
  std::shared_ptr<livekit::LocalAudioTrack> microphone_track_;
  std::shared_ptr<livekit::VideoSource> screen_source_;
  std::shared_ptr<livekit::LocalVideoTrack> screen_track_;
  ScreenCapturer screen_capturer_{1920, 1080, 30};
  std::atomic<bool> connected_{false};
  std::atomic<bool> shutting_down_{false};
};

}  // namespace meeting
