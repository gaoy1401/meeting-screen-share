#include "meeting/meeting_window.h"

#ifdef _WIN32
#include <commctrl.h>
#include <windowsx.h>
#endif

#include <algorithm>
#include <memory>
#include <stdexcept>
#include <utility>

namespace meeting {
namespace {

constexpr wchar_t kWindowClass[] = L"MeetingWebRTCWindowsClient";
constexpr UINT kStatusMessage = WM_APP + 1;
constexpr UINT kParticipantMessage = WM_APP + 2;
constexpr UINT kVideoMessage = WM_APP + 3;
constexpr UINT kConnectedMessage = WM_APP + 4;
constexpr UINT kMicrophoneMessage = WM_APP + 5;
constexpr UINT kScreenMessage = WM_APP + 6;
constexpr int kServerEdit = 101;
constexpr int kRoomEdit = 102;
constexpr int kNameEdit = 103;
constexpr int kJoinButton = 104;
constexpr int kMicrophoneButton = 105;
constexpr int kScreenButton = 106;

std::wstring fromUtf8(const std::string& text) {
  if (text.empty()) return {};
  const int count = MultiByteToWideChar(
      CP_UTF8,
      MB_ERR_INVALID_CHARS,
      text.data(),
      static_cast<int>(text.size()),
      nullptr,
      0);
  if (count <= 0) return L"文本解码失败";
  std::wstring result(static_cast<std::size_t>(count), L'\0');
  MultiByteToWideChar(
      CP_UTF8,
      MB_ERR_INVALID_CHARS,
      text.data(),
      static_cast<int>(text.size()),
      result.data(),
      count);
  return result;
}

std::string toUtf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int count = WideCharToMultiByte(
      CP_UTF8,
      WC_ERR_INVALID_CHARS,
      text.data(),
      static_cast<int>(text.size()),
      nullptr,
      0,
      nullptr,
      nullptr);
  if (count <= 0) throw std::runtime_error("无法把输入转换为 UTF-8");
  std::string result(static_cast<std::size_t>(count), '\0');
  WideCharToMultiByte(
      CP_UTF8,
      WC_ERR_INVALID_CHARS,
      text.data(),
      static_cast<int>(text.size()),
      result.data(),
      count,
      nullptr,
      nullptr);
  return result;
}

void setDefaultFont(HWND control) {
  SendMessage(
      control,
      WM_SETFONT,
      reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),
      TRUE);
}

HWND createLabel(
    HWND parent,
    HINSTANCE instance,
    const wchar_t* text) {
  HWND control = CreateWindowEx(
      0,
      L"STATIC",
      text,
      WS_CHILD | WS_VISIBLE | SS_LEFT,
      0,
      0,
      0,
      0,
      parent,
      nullptr,
      instance,
      nullptr);
  setDefaultFont(control);
  return control;
}

}  // namespace

MeetingWindow::MeetingWindow()
    : client_({
          .on_status = [this](std::string value) {
            postStatus(std::move(value));
          },
          .on_participant_count = [this](int value) {
            postParticipantCount(value);
          },
          .on_video_frame = [this](RemoteVideoFrame value) {
            postVideoFrame(std::move(value));
          },
          .on_connected = [this](bool value) {
            postBoolean(kConnectedMessage, value);
          },
          .on_microphone_changed = [this](bool value) {
            postBoolean(kMicrophoneMessage, value);
          },
          .on_screen_share_changed = [this](bool value) {
            postBoolean(kScreenMessage, value);
          },
      }) {}

MeetingWindow::~MeetingWindow() {
  destroyVideoBackBuffer();
}

bool MeetingWindow::create(HINSTANCE instance, int show_command) {
  instance_ = instance;
  WNDCLASSEX window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = windowProcedure;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  window_class.hbrBackground =
      reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  window_class.lpszClassName = kWindowClass;
  RegisterClassEx(&window_class);

  window_ = CreateWindowEx(
      0,
      kWindowClass,
      L"Meeting WebRTC · Windows",
      WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      1040,
      760,
      nullptr,
      nullptr,
      instance,
      this);
  if (!window_) return false;
  ShowWindow(window_, show_command);
  UpdateWindow(window_);
  return true;
}

int MeetingWindow::runMessageLoop() {
  MSG message{};
  while (GetMessage(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
  return static_cast<int>(message.wParam);
}

LRESULT CALLBACK MeetingWindow::windowProcedure(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  MeetingWindow* self = reinterpret_cast<MeetingWindow*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    self = static_cast<MeetingWindow*>(create->lpCreateParams);
    SetWindowLongPtr(
        window,
        GWLP_USERDATA,
        reinterpret_cast<LONG_PTR>(self));
    self->window_ = window;
  }
  if (self) return self->handleMessage(message, wparam, lparam);
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT MeetingWindow::handleMessage(
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  switch (message) {
    case WM_CREATE:
      createControls();
      return 0;
    case WM_SIZE:
      layoutControls(LOWORD(lparam), HIWORD(lparam));
      return 0;
    case WM_COMMAND:
      if (HIWORD(wparam) == BN_CLICKED) {
        switch (LOWORD(wparam)) {
          case kJoinButton:
            toggleConnection();
            return 0;
          case kMicrophoneButton:
            client_.setMicrophoneEnabled(!microphone_enabled_);
            return 0;
          case kScreenButton:
            client_.setScreenShareEnabled(!screen_share_enabled_);
            return 0;
        }
      }
      break;
    case WM_PAINT:
      paint();
      return 0;
    case kStatusMessage: {
      std::unique_ptr<std::wstring> status(
          reinterpret_cast<std::wstring*>(lparam));
      if (status_label_) SetWindowText(status_label_, status->c_str());
      return 0;
    }
    case kParticipantMessage: {
      const std::wstring text =
          std::to_wstring(static_cast<int>(wparam)) + L" 人在线";
      SetWindowText(participant_label_, text.c_str());
      return 0;
    }
    case kVideoMessage: {
      {
        std::lock_guard lock(pending_video_mutex_);
        if (pending_video_) {
          video_frame_ = std::make_unique<RemoteVideoFrame>(
              std::move(*pending_video_));
          pending_video_.reset();
        }
      }
      video_message_pending_.store(false);
      bool has_newer_frame = false;
      {
        std::lock_guard lock(pending_video_mutex_);
        has_newer_frame = pending_video_.has_value();
      }
      if (has_newer_frame && !video_message_pending_.exchange(true)) {
        if (!PostMessage(window_, kVideoMessage, 0, 0)) {
          video_message_pending_.store(false);
        }
      }
      RECT client{};
      GetClientRect(window_, &client);
      RECT video_rect{
          18,
          122,
          std::max(19L, client.right - 18),
          std::max(123L, client.bottom - 44)};
      InvalidateRect(window_, &video_rect, FALSE);
      return 0;
    }
    case kConnectedMessage:
      updateConnected(wparam != 0);
      return 0;
    case kMicrophoneMessage:
      microphone_enabled_ = wparam != 0;
      SetWindowText(
          microphone_button_,
          microphone_enabled_ ? L"关闭麦克风" : L"开启麦克风");
      return 0;
    case kScreenMessage:
      screen_share_enabled_ = wparam != 0;
      SetWindowText(
          screen_button_,
          screen_share_enabled_ ? L"停止共享" : L"共享屏幕");
      return 0;
    case WM_DESTROY:
      destroyVideoBackBuffer();
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProc(window_, message, wparam, lparam);
}

void MeetingWindow::createControls() {
  createLabel(window_, instance_, L"服务器");
  createLabel(window_, instance_, L"房间号");
  createLabel(window_, instance_, L"昵称");

  server_edit_ = CreateWindowEx(
      WS_EX_CLIENTEDGE,
      L"EDIT",
      L"127.0.0.1:9000",
      WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
      0,
      0,
      0,
      0,
      window_,
      reinterpret_cast<HMENU>(kServerEdit),
      instance_,
      nullptr);
  room_edit_ = CreateWindowEx(
      WS_EX_CLIENTEDGE,
      L"EDIT",
      L"demo",
      WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
      0,
      0,
      0,
      0,
      window_,
      reinterpret_cast<HMENU>(kRoomEdit),
      instance_,
      nullptr);

  wchar_t computer_name[MAX_COMPUTERNAME_LENGTH + 1]{};
  DWORD computer_name_length = MAX_COMPUTERNAME_LENGTH + 1;
  if (!GetComputerName(computer_name, &computer_name_length)) {
    wcscpy_s(computer_name, L"Windows");
  }
  name_edit_ = CreateWindowEx(
      WS_EX_CLIENTEDGE,
      L"EDIT",
      computer_name,
      WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
      0,
      0,
      0,
      0,
      window_,
      reinterpret_cast<HMENU>(kNameEdit),
      instance_,
      nullptr);
  join_button_ = CreateWindowEx(
      0,
      L"BUTTON",
      L"加入会议",
      WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
      0,
      0,
      0,
      0,
      window_,
      reinterpret_cast<HMENU>(kJoinButton),
      instance_,
      nullptr);
  microphone_button_ = CreateWindowEx(
      0,
      L"BUTTON",
      L"开启麦克风",
      WS_CHILD | WS_VISIBLE,
      0,
      0,
      0,
      0,
      window_,
      reinterpret_cast<HMENU>(kMicrophoneButton),
      instance_,
      nullptr);
  screen_button_ = CreateWindowEx(
      0,
      L"BUTTON",
      L"共享屏幕",
      WS_CHILD | WS_VISIBLE,
      0,
      0,
      0,
      0,
      window_,
      reinterpret_cast<HMENU>(kScreenButton),
      instance_,
      nullptr);
  participant_label_ = createLabel(window_, instance_, L"0 人在线");
  codec_label_ = createLabel(
      window_,
      instance_,
      L"Windows：H264 · WebRTC/UDP 优先");
  status_label_ = createLabel(window_, instance_, L"尚未连接");

  for (HWND control :
       {server_edit_,
        room_edit_,
        name_edit_,
        join_button_,
        microphone_button_,
        screen_button_}) {
    setDefaultFont(control);
  }
  EnableWindow(microphone_button_, FALSE);
  EnableWindow(screen_button_, FALSE);

  RECT client{};
  GetClientRect(window_, &client);
  layoutControls(client.right, client.bottom);
}

void MeetingWindow::layoutControls(int width, int height) {
  if (!server_edit_) return;
  constexpr int margin = 18;
  constexpr int label_height = 18;
  constexpr int edit_height = 28;
  constexpr int top = 16;
  const int server_width = 230;
  const int room_width = 120;
  const int name_width = 160;
  const int join_width = 112;
  const int gap = 10;

  const auto labels = [&] {
    HWND child = GetWindow(window_, GW_CHILD);
    int count = 0;
    while (child && count < 3) {
      if (GetDlgCtrlID(child) == 0) {
        const int x =
            count == 0 ? margin :
            count == 1 ? margin + server_width + gap :
                         margin + server_width + room_width + gap * 2;
        const int item_width =
            count == 0 ? server_width :
            count == 1 ? room_width : name_width;
        MoveWindow(child, x, top, item_width, label_height, TRUE);
        ++count;
      }
      child = GetWindow(child, GW_HWNDNEXT);
    }
  };
  labels();

  int x = margin;
  const int edit_y = top + label_height + 4;
  MoveWindow(server_edit_, x, edit_y, server_width, edit_height, TRUE);
  x += server_width + gap;
  MoveWindow(room_edit_, x, edit_y, room_width, edit_height, TRUE);
  x += room_width + gap;
  MoveWindow(name_edit_, x, edit_y, name_width, edit_height, TRUE);
  x += name_width + gap;
  MoveWindow(join_button_, x, edit_y - 1, join_width, edit_height + 2, TRUE);

  const int actions_y = edit_y + edit_height + 14;
  MoveWindow(microphone_button_, margin, actions_y, 116, 30, TRUE);
  MoveWindow(screen_button_, margin + 126, actions_y, 116, 30, TRUE);
  MoveWindow(participant_label_, margin + 262, actions_y + 6, 100, 22, TRUE);
  MoveWindow(codec_label_, margin + 370, actions_y + 6, 260, 22, TRUE);
  MoveWindow(
      status_label_,
      margin,
      height - 34,
      std::max(100, width - margin * 2),
      22,
      TRUE);
}

void MeetingWindow::paint() {
  PAINTSTRUCT paint{};
  HDC dc = BeginPaint(window_, &paint);
  RECT client{};
  GetClientRect(window_, &client);
  RECT video_rect{
      18,
      122,
      std::max(19L, client.right - 18),
      std::max(123L, client.bottom - 44)};
  const int available_width = video_rect.right - video_rect.left;
  const int available_height = video_rect.bottom - video_rect.top;
  if (!ensureVideoBackBuffer(dc, available_width, available_height)) {
    FillRect(dc, &video_rect, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    EndPaint(window_, &paint);
    return;
  }

  RECT buffer_rect{0, 0, available_width, available_height};
  FillRect(
      video_back_buffer_dc_,
      &buffer_rect,
      static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));

  if (video_frame_ && video_frame_->width > 0 &&
      video_frame_->height > 0 && !video_frame_->bgra.empty()) {
    const double scale = std::min(
        static_cast<double>(available_width) / video_frame_->width,
        static_cast<double>(available_height) / video_frame_->height);
    const int draw_width =
        std::max(1, static_cast<int>(video_frame_->width * scale));
    const int draw_height =
        std::max(1, static_cast<int>(video_frame_->height * scale));
    const int draw_x = (available_width - draw_width) / 2;
    const int draw_y = (available_height - draw_height) / 2;

    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = video_frame_->width;
    bitmap_info.bmiHeader.biHeight = -video_frame_->height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    // Render the complete frame off-screen and present it with one BitBlt.
    // Clearing the real window before StretchDIBits caused a visible black
    // flash on every received frame.
    SetStretchBltMode(video_back_buffer_dc_, COLORONCOLOR);
    StretchDIBits(
        video_back_buffer_dc_,
        draw_x,
        draw_y,
        draw_width,
        draw_height,
        0,
        0,
        video_frame_->width,
        video_frame_->height,
        video_frame_->bgra.data(),
        &bitmap_info,
        DIB_RGB_COLORS,
        SRCCOPY);
  } else {
    SetBkMode(video_back_buffer_dc_, TRANSPARENT);
    SetTextColor(video_back_buffer_dc_, RGB(205, 205, 205));
    DrawText(
        video_back_buffer_dc_,
        L"等待同房间成员共享屏幕",
        -1,
        &buffer_rect,
        DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
  BitBlt(
      dc,
      video_rect.left,
      video_rect.top,
      available_width,
      available_height,
      video_back_buffer_dc_,
      0,
      0,
      SRCCOPY);
  EndPaint(window_, &paint);
}

bool MeetingWindow::ensureVideoBackBuffer(
    HDC target,
    int width,
    int height) {
  if (video_back_buffer_dc_ && video_back_buffer_bitmap_ &&
      video_back_buffer_size_.cx == width &&
      video_back_buffer_size_.cy == height) {
    return true;
  }

  destroyVideoBackBuffer();
  video_back_buffer_dc_ = CreateCompatibleDC(target);
  if (!video_back_buffer_dc_) return false;

  video_back_buffer_bitmap_ = CreateCompatibleBitmap(target, width, height);
  if (!video_back_buffer_bitmap_) {
    destroyVideoBackBuffer();
    return false;
  }
  video_back_buffer_previous_bitmap_ = SelectObject(
      video_back_buffer_dc_,
      video_back_buffer_bitmap_);
  video_back_buffer_size_.cx = width;
  video_back_buffer_size_.cy = height;
  return true;
}

void MeetingWindow::destroyVideoBackBuffer() {
  if (video_back_buffer_dc_ && video_back_buffer_previous_bitmap_) {
    SelectObject(
        video_back_buffer_dc_,
        video_back_buffer_previous_bitmap_);
  }
  if (video_back_buffer_bitmap_) {
    DeleteObject(video_back_buffer_bitmap_);
  }
  if (video_back_buffer_dc_) {
    DeleteDC(video_back_buffer_dc_);
  }
  video_back_buffer_dc_ = nullptr;
  video_back_buffer_bitmap_ = nullptr;
  video_back_buffer_previous_bitmap_ = nullptr;
  video_back_buffer_size_ = {};
}

void MeetingWindow::toggleConnection() {
  if (connected_) {
    client_.disconnect();
    SetWindowText(status_label_, L"正在离开会议...");
    return;
  }
  try {
    const auto server = toUtf8(controlText(server_edit_));
    const auto room = toUtf8(controlText(room_edit_));
    const auto name = toUtf8(controlText(name_edit_));
    if (server.empty() || room.empty() || name.empty()) {
      throw std::invalid_argument("服务器、房间号和昵称不能为空");
    }
    EnableWindow(join_button_, FALSE);
    SetWindowText(status_label_, L"正在加入会议...");
    client_.connect(server, room, name);
  } catch (const std::exception& error) {
    SetWindowText(status_label_, fromUtf8(error.what()).c_str());
  }
}

void MeetingWindow::updateConnected(bool connected) {
  connected_ = connected;
  EnableWindow(server_edit_, !connected);
  EnableWindow(room_edit_, !connected);
  EnableWindow(name_edit_, !connected);
  EnableWindow(join_button_, TRUE);
  EnableWindow(microphone_button_, connected);
  EnableWindow(screen_button_, connected);
  SetWindowText(join_button_, connected ? L"离开会议" : L"加入会议");
  if (!connected) {
    microphone_enabled_ = false;
    screen_share_enabled_ = false;
    SetWindowText(microphone_button_, L"开启麦克风");
    SetWindowText(screen_button_, L"共享屏幕");
  }
}

void MeetingWindow::postStatus(std::string status) {
  auto value = std::make_unique<std::wstring>(fromUtf8(status));
  if (!window_ ||
      !PostMessage(
          window_,
          kStatusMessage,
          0,
          reinterpret_cast<LPARAM>(value.get()))) {
    return;
  }
  value.release();
}

void MeetingWindow::postParticipantCount(int count) {
  if (window_) {
    PostMessage(window_, kParticipantMessage, static_cast<WPARAM>(count), 0);
  }
}

void MeetingWindow::postVideoFrame(RemoteVideoFrame frame) {
  {
    std::lock_guard lock(pending_video_mutex_);
    pending_video_ = std::move(frame);
  }
  if (video_message_pending_.exchange(true)) {
    return;
  }
  if (!window_ || !PostMessage(window_, kVideoMessage, 0, 0)) {
    video_message_pending_.store(false);
  }
}

void MeetingWindow::postBoolean(UINT message, bool value) {
  if (window_) {
    PostMessage(window_, message, value ? 1 : 0, 0);
  }
}

std::wstring MeetingWindow::controlText(HWND control) const {
  const int length = GetWindowTextLength(control);
  std::wstring value(static_cast<std::size_t>(length) + 1, L'\0');
  if (length > 0) {
    GetWindowText(control, value.data(), length + 1);
  }
  value.resize(static_cast<std::size_t>(length));
  return value;
}

}  // namespace meeting
