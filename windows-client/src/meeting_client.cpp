#include "meeting/meeting_client.h"

#include "meeting/codec_policy.h"

#include <chrono>
#include <exception>
#include <random>
#include <stdexcept>
#include <utility>

namespace meeting {
namespace {

constexpr char kAuxiliaryScreenIdentity[] = "pxg-screen";

std::uint32_t randomSessionId() {
  std::random_device device;
  std::mt19937 generator(device());
  std::uniform_int_distribution<std::uint32_t> distribution(
      1,
      0xffffffffU);
  return distribution(generator);
}

std::string errorMessage(const std::exception& error) {
  return error.what() && *error.what() ? error.what() : "unknown error";
}

}  // namespace

MeetingClient::MeetingClient(MeetingCallbacks callbacks)
    : callbacks_(std::move(callbacks)) {
  livekit::initialize(livekit::LogLevel::Info);
}

MeetingClient::~MeetingClient() {
  shutting_down_.store(true);
  executor_.post([this] { disconnectImpl(false); });
  executor_.stop();
  livekit::shutdown();
}

void MeetingClient::connect(
    std::string server_address,
    std::string room,
    std::string display_name) {
  executor_.post(
      [this,
       server_address = std::move(server_address),
       room = std::move(room),
       display_name = std::move(display_name)] {
        connectImpl(server_address, room, display_name);
      });
}

void MeetingClient::disconnect() {
  executor_.post([this] { disconnectImpl(true); });
}

void MeetingClient::setMicrophoneEnabled(bool enabled) {
  executor_.post([this, enabled] { setMicrophoneImpl(enabled); });
}

void MeetingClient::setScreenShareEnabled(bool enabled) {
  executor_.post([this, enabled] { setScreenShareImpl(enabled); });
}

void MeetingClient::connectImpl(
    const std::string& server_address,
    const std::string& room,
    const std::string& display_name) {
  try {
    disconnectImpl(false);
    emitStatus("正在连接可靠信令...");
    const auto endpoint = parseServerEndpoint(server_address);
    const auto credentials = signaling_.join(
        endpoint,
        {
            .room = room,
            .display_name = display_name,
            .session_id = randomSessionId(),
        });

    emitStatus("正在连接 WebRTC SFU...");
    try {
      ensurePlatformAudio();
    } catch (const std::exception& audio_error) {
      emitStatus(
          "音频设备不可用，仍继续入会：" + errorMessage(audio_error));
    }
    room_ = std::make_unique<livekit::Room>();
    room_->setDelegate(this);
    livekit::RoomOptions options;
    options.auto_subscribe = true;
    options.dynacast = true;
    if (!room_->connect(credentials.url, credentials.token, options)) {
      throw std::runtime_error("LiveKit room connection failed");
    }
    connected_.store(true);
    if (callbacks_.on_connected) callbacks_.on_connected(true);
    emitParticipantCount(*room_);
    emitStatus("已加入房间，媒体使用 WebRTC/SRTP，Windows 视频为 H264");
  } catch (const std::exception& error) {
    disconnectImpl(false);
    emitStatus("入会失败：" + errorMessage(error));
    if (callbacks_.on_connected) callbacks_.on_connected(false);
  }
}

void MeetingClient::disconnectImpl(bool report_status) {
  screen_capturer_.stop();
  screen_source_.reset();
  screen_track_.reset();
  microphone_source_.reset();
  microphone_track_.reset();

  if (room_) {
    room_->setDelegate(nullptr);
    room_.reset();
  }
  signaling_.disconnect();
  connected_.store(false);
  if (callbacks_.on_connected) callbacks_.on_connected(false);
  if (callbacks_.on_microphone_changed) {
    callbacks_.on_microphone_changed(false);
  }
  if (callbacks_.on_screen_share_changed) {
    callbacks_.on_screen_share_changed(false);
  }
  if (callbacks_.on_participant_count) callbacks_.on_participant_count(0);
  if (report_status) emitStatus("已离开会议");
}

void MeetingClient::setMicrophoneImpl(bool enabled) {
  try {
    if (!connected_.load() || !room_) {
      throw std::runtime_error("尚未加入房间");
    }
    if (!enabled) {
      if (microphone_track_) microphone_track_->mute();
      if (callbacks_.on_microphone_changed) {
        callbacks_.on_microphone_changed(false);
      }
      emitStatus("麦克风已关闭");
      return;
    }
    if (microphone_track_) {
      microphone_track_->unmute();
    } else {
      ensurePlatformAudio();
      livekit::PlatformAudioOptions audio_options;
      audio_options.echo_cancellation = true;
      audio_options.noise_suppression = true;
      audio_options.auto_gain_control = true;
      auto source = platform_audio_->createAudioSource(audio_options);
      auto track = livekit::LocalAudioTrack::createLocalAudioTrack(
          "microphone",
          source);
      livekit::TrackPublishOptions publish_options;
      publish_options.source = livekit::TrackSource::SOURCE_MICROPHONE;
      publish_options.dtx = true;
      publish_options.red = true;
      auto participant = room_->localParticipant().lock();
      if (!participant) throw std::runtime_error("local participant is unavailable");
      participant->publishTrack(track, publish_options);
      microphone_source_ = std::move(source);
      microphone_track_ = std::move(track);
    }
    if (callbacks_.on_microphone_changed) {
      callbacks_.on_microphone_changed(true);
    }
    emitStatus("麦克风已开启，音频使用 WebRTC/Opus");
  } catch (const std::exception& error) {
    if (callbacks_.on_microphone_changed) {
      callbacks_.on_microphone_changed(false);
    }
    emitStatus("麦克风启动失败：" + errorMessage(error));
  }
}

void MeetingClient::setScreenShareImpl(bool enabled) {
  try {
    if (!connected_.load() || !room_) {
      throw std::runtime_error("尚未加入房间");
    }
    if (!enabled) {
      screen_capturer_.stop();
      if (screen_track_) {
        if (auto publication = screen_track_->publication()) {
          if (auto participant = room_->localParticipant().lock()) {
            participant->unpublishTrack(publication->sid());
          }
        }
      }
      screen_track_.reset();
      screen_source_.reset();
      if (callbacks_.on_screen_share_changed) {
        callbacks_.on_screen_share_changed(false);
      }
      emitStatus("屏幕共享已停止");
      return;
    }
    if (screen_track_) return;

    auto source = std::make_shared<livekit::VideoSource>(1920, 1080);
    auto track = livekit::LocalVideoTrack::createLocalVideoTrack(
        "screen_share",
        source);
    livekit::TrackPublishOptions publish_options;
    publish_options.source = livekit::TrackSource::SOURCE_SCREENSHARE;
    publish_options.video_codec = h264Codec();
    publish_options.simulcast = false;
    publish_options.degradation_preference =
        livekit::DegradationPreference::MaintainResolution;
    publish_options.video_encoding = livekit::VideoEncodingOptions{
        .max_bitrate = 6'000'000,
        .max_framerate = 30,
    };
    auto participant = room_->localParticipant().lock();
    if (!participant) throw std::runtime_error("local participant is unavailable");
    participant->publishTrack(track, publish_options);
    screen_source_ = source;
    screen_track_ = track;
    screen_capturer_.start(
        source,
        [this](std::string message) {
          emitStatus("屏幕采集失败：" + message);
          if (!shutting_down_.load()) {
            executor_.post([this] { setScreenShareImpl(false); });
          }
        });
    if (callbacks_.on_screen_share_changed) {
      callbacks_.on_screen_share_changed(true);
    }
    emitStatus("正在共享屏幕：1920x1080 30 FPS，H264");
  } catch (const std::exception& error) {
    screen_capturer_.stop();
    screen_track_.reset();
    screen_source_.reset();
    if (callbacks_.on_screen_share_changed) {
      callbacks_.on_screen_share_changed(false);
    }
    emitStatus("屏幕共享失败：" + errorMessage(error));
  }
}

void MeetingClient::ensurePlatformAudio() {
  if (platform_audio_) return;
  platform_audio_ = std::make_unique<livekit::PlatformAudio>();
}

void MeetingClient::onParticipantConnected(
    livekit::Room& room,
    const livekit::ParticipantConnectedEvent&) {
  emitParticipantCount(room);
}

void MeetingClient::onParticipantDisconnected(
    livekit::Room& room,
    const livekit::ParticipantDisconnectedEvent&) {
  emitParticipantCount(room);
}

void MeetingClient::onTrackSubscribed(
    livekit::Room& room,
    const livekit::TrackSubscribedEvent& event) {
  if (!event.track || !event.publication || !event.participant ||
      event.track->kind() != livekit::TrackKind::KIND_VIDEO ||
      (event.publication->source() !=
           livekit::TrackSource::SOURCE_SCREENSHARE &&
       event.participant->identity() != kAuxiliaryScreenIdentity)) {
    return;
  }

  livekit::VideoStream::Options options;
  options.capacity = 2;
  options.format = livekit::VideoBufferType::BGRA;
  room.setOnVideoFrameCallback(
      event.participant->identity(),
      event.publication->name(),
      [this](const livekit::VideoFrame& frame, std::int64_t) {
        if (!callbacks_.on_video_frame || shutting_down_.load()) return;
        RemoteVideoFrame copy;
        copy.width = frame.width();
        copy.height = frame.height();
        copy.bgra.assign(frame.data(), frame.data() + frame.dataSize());
        callbacks_.on_video_frame(std::move(copy));
      },
      options);
  emitStatus(
      "已订阅远端屏幕：" + event.publication->mimeType());
}

void MeetingClient::onTrackUnsubscribed(
    livekit::Room& room,
    const livekit::TrackUnsubscribedEvent& event) {
  if (!event.publication || !event.participant ||
      (event.publication->source() !=
           livekit::TrackSource::SOURCE_SCREENSHARE &&
       event.participant->identity() != kAuxiliaryScreenIdentity)) {
    return;
  }
  room.clearOnVideoFrameCallback(
      event.participant->identity(),
      event.publication->name());
}

void MeetingClient::onReconnecting(
    livekit::Room&,
    const livekit::ReconnectingEvent&) {
  emitStatus("网络波动，WebRTC 正在自动重连...");
}

void MeetingClient::onReconnected(
    livekit::Room&,
    const livekit::ReconnectedEvent&) {
  emitStatus("WebRTC 已恢复连接");
}

void MeetingClient::onDisconnected(
    livekit::Room&,
    const livekit::DisconnectedEvent&) {
  connected_.store(false);
  if (callbacks_.on_connected) callbacks_.on_connected(false);
  emitStatus("WebRTC 已断开");
}

void MeetingClient::emitParticipantCount(livekit::Room& room) {
  int count = 1;
  for (const auto& participant : room.remoteParticipants()) {
    if (const auto locked = participant.lock();
        locked && locked->identity() != kAuxiliaryScreenIdentity) {
      ++count;
    }
  }
  if (callbacks_.on_participant_count) callbacks_.on_participant_count(count);
}

void MeetingClient::emitStatus(std::string message) const {
  if (callbacks_.on_status && !shutting_down_.load()) {
    callbacks_.on_status(std::move(message));
  }
}

}  // namespace meeting
