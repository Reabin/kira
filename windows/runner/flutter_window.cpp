#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_state.h"

#ifndef WM_DPICHANGED_BEFOREPARENT
#define WM_DPICHANGED_BEFOREPARENT 0x02E2
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    SyncInitialDpi();
    window_state_ready_ = true;
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SyncInitialDpi() {
  // The engine starts with the system DPI and only tracks per-monitor DPI from
  // WM_DPICHANGED_BEFOREPARENT. Restoring a window straight onto a monitor with
  // a different scale factor skips that notification, which leaves the UI
  // drawn at the wrong scale until the user drags it across monitors.
  const HWND hwnd = flutter_controller_->view()->GetNativeWindow();
  if (hwnd == nullptr) {
    return;
  }
  SendMessageW(hwnd, WM_DPICHANGED_BEFOREPARENT, GetDpiForWindow(hwnd), 0);
  RECT client;
  GetClientRect(hwnd, &client);
  SendMessageW(hwnd, WM_SIZE, SIZE_RESTORED,
               MAKELPARAM(client.right - client.left, client.bottom - client.top));
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Save before Flutter's cancelable-exit handler can consume WM_CLOSE.
  // Dragging writes once on release; other moves (snap, maximize, DPI changes)
  // are saved immediately, including when the debugger later kills the app.
  if (window_state_ready_) {
    bool save_state = false;
    switch (message) {
      case WM_ENTERSIZEMOVE:
        sizing_or_moving_ = true;
        break;
      case WM_EXITSIZEMOVE:
        sizing_or_moving_ = false;
        save_state = true;
        break;
      case WM_WINDOWPOSCHANGED: {
        const auto* position = reinterpret_cast<const WINDOWPOS*>(lparam);
        save_state = !sizing_or_moving_ &&
                     (position->flags & (SWP_NOMOVE | SWP_NOSIZE)) !=
                         (SWP_NOMOVE | SWP_NOSIZE);
        break;
      }
      case WM_CLOSE:
      case WM_QUERYENDSESSION:
      case WM_ENDSESSION:
      case WM_DESTROY:
        save_state = true;
        break;
    }
    if (save_state && IsWindowVisible(hwnd) && !IsIconic(hwnd) &&
        !IsZoomed(hwnd) && !window_state::Save(hwnd)) {
      OutputDebugStringW(L"kira: failed to save window state.\n");
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
