#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

bool ContainsInsensitive(const std::string& text, const std::string& needle) {
  std::string haystack = text;
  std::string target = needle;
  std::transform(haystack.begin(), haystack.end(), haystack.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  std::transform(target.begin(), target.end(), target.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return haystack.find(target) != std::string::npos;
}

bool ShouldForceVRegisterMaximized(const std::vector<std::string>& args) {
  (void)args;

  // Environment fallback for deterministic local testing.
  // Example: $env:PAAAYIT_FORCE_MAXIMIZE='1'
  char* force_max_raw = nullptr;
  size_t force_max_len = 0;
  if (_dupenv_s(&force_max_raw, &force_max_len, "PAAAYIT_FORCE_MAXIMIZE") == 0 &&
      force_max_raw != nullptr) {
    const std::string v(force_max_raw);
    free(force_max_raw);
    if (ContainsInsensitive(v, "1") || ContainsInsensitive(v, "true") ||
        ContainsInsensitive(v, "yes")) {
      return true;
    }
  }

  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const bool force_maximized = ShouldForceVRegisterMaximized(command_line_arguments);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Terminal-first launch size.
  // Keep ~0.10in (about 10px @ 96 DPI) margin around terminal content.
  constexpr int kTerminalFramePaddingPx = 10;
  constexpr double kTerminalAspect = 19.5 / 9.0;  // Matches login terminal frame.
  // Give the terminal shell a little extra vertical room for customer details.
  constexpr int kWindowHeight = 990;

  // Compute width so left/right padding matches top/bottom padding.
  const int terminal_canvas_height = kWindowHeight - (kTerminalFramePaddingPx * 2);
  const int terminal_canvas_width = static_cast<int>(terminal_canvas_height / kTerminalAspect);
  const int kWindowWidth = terminal_canvas_width + (kTerminalFramePaddingPx * 2);

  // Small breathing room from screen edges.
  constexpr int kEdgePadding = 6;

  // Use the desktop work area (taskbar excluded), then dock top-right.
  RECT work_area = {0, 0, 0, 0};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);

  const int origin_x = work_area.right - kWindowWidth - kEdgePadding;
  const int origin_y = work_area.top + kEdgePadding;

  FlutterWindow window(project);
  if (force_maximized) {
    window.SetShowCommand(SW_SHOWMAXIMIZED);
  }
  Win32Window::Point origin(origin_x, origin_y);
  Win32Window::Size size(kWindowWidth, kWindowHeight);
  if (!window.Create(L"PaaayIT.com", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
