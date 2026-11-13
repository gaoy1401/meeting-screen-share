#include "meeting/meeting_window.h"

#ifdef _WIN32
#include <commctrl.h>
#include <windows.h>
#endif

int WINAPI wWinMain(
    HINSTANCE instance,
    HINSTANCE,
    PWSTR,
    int show_command) {
  SetProcessDPIAware();
  INITCOMMONCONTROLSEX controls{
      .dwSize = sizeof(INITCOMMONCONTROLSEX),
      .dwICC = ICC_STANDARD_CLASSES,
  };
  InitCommonControlsEx(&controls);

  meeting::MeetingWindow window;
  if (!window.create(instance, show_command)) {
    MessageBox(
        nullptr,
        L"无法创建 Windows 会议客户端窗口。",
        L"Meeting WebRTC",
        MB_OK | MB_ICONERROR);
    return 1;
  }
  return window.runMessageLoop();
}
