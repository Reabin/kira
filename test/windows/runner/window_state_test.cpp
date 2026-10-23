#include "../../../windows/runner/window_state.h"
#include "../../../windows/runner/win32_window.h"

#include <flutter_windows.h>

#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void Check(bool condition, const char* message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

RECT WindowRect(HWND window) {
  RECT rect{};
  Check(GetWindowRect(window, &rect) != FALSE, "GetWindowRect failed");
  return rect;
}

BOOL CALLBACK CollectMonitors(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto& monitors = *reinterpret_cast<std::vector<MONITORINFO>*>(data);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, &info)) {
    monitors.push_back(info);
  }
  return TRUE;
}

class Fixture {
 public:
  Fixture() {
    wchar_t temp[MAX_PATH];
    wchar_t directory[MAX_PATH];
    Check(GetTempPathW(MAX_PATH, temp) != 0, "GetTempPath failed");
    Check(GetTempFileNameW(temp, L"kws", 0, directory) != 0,
          "GetTempFileName failed");
    Check(DeleteFileW(directory) != FALSE, "Remove temporary file failed");
    Check(CreateDirectoryW(directory, nullptr) != FALSE,
          "Create temporary directory failed");
    directory_ = directory;
    path = directory_ + L"\\window_state.txt";
  }

  ~Fixture() {
    DeleteFileW(path.c_str());
    DeleteFileW((path + L".tmp").c_str());
    RemoveDirectoryW(directory_.c_str());
  }

  void Write(const std::string& state) {
    std::ofstream file(path, std::ios::trunc);
    file << state;
    Check(file.good(), "Write test state failed");
  }

  std::string Read() {
    std::ifstream file(path);
    Check(file.is_open(), "Read test state failed");
    return std::string(std::istreambuf_iterator<char>(file),
                       std::istreambuf_iterator<char>());
  }

  std::wstring path;

 private:
  std::wstring directory_;
};

// Capture the DPI at exactly the point FlutterWindow initializes its engine.
class ProbeWindow : public Win32Window {
 public:
  UINT initial_dpi = 0;
  RECT initial_bounds{};

 protected:
  bool OnCreate() override {
    initial_dpi = GetDpiForWindow(GetHandle());
    initial_bounds = WindowRect(GetHandle());
    return true;
  }
};

void RunTests(Fixture& fixture) {
  const std::wstring& path = fixture.path;
  RECT loaded{};
  Check(!window_state::Load(loaded, path), "Missing state must use defaults");

  std::vector<MONITORINFO> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitors,
                      reinterpret_cast<LPARAM>(&monitors));
  Check(!monitors.empty(), "No monitors found");
  for (const MONITORINFO& monitor : monitors) {
    const RECT& work = monitor.rcWork;
    const RECT expected = {work.left + 50, work.top + 50,
                           work.left + 450, work.top + 550};
    ProbeWindow window;
    Check(window.Create(L"Window state test", {10, 10}, {440, 950}, &expected),
          "Create window at saved position failed");
    Check(EqualRect(&window.initial_bounds, &expected) != FALSE,
          "Saved physical bounds were scaled at creation");
    const UINT target_dpi = FlutterDesktopGetDpiForMonitor(
        MonitorFromWindow(window.GetHandle(), MONITOR_DEFAULTTONEAREST));
    Check(window.initial_dpi == target_dpi,
          "Initial DPI must match the target monitor before engine creation");
    std::cout << "Target monitor DPI: " << target_dpi << '\n';
    Check(!window_state::Save(window.GetHandle(), path),
          "Hidden startup window must not overwrite state");
    window.Show();
    Check(window_state::Save(window.GetHandle(), path), "Save failed");
    Check(window_state::Load(loaded, path), "Load saved state failed");
    Check(EqualRect(&loaded, &expected) != FALSE, "Saved bounds changed");

    ProbeWindow reopened;
    Check(reopened.Create(L"Reopened window test", {10, 10}, {440, 950}, &loaded),
          "Reopen window failed");
    Check(reopened.initial_dpi == window.initial_dpi,
          "Reopened engine would initialize with another monitor's DPI");
    Check(EqualRect(&reopened.initial_bounds, &expected) != FALSE,
          "Reopening must retain exact physical position and size");

    const RECT resized = {work.left + 70, work.top + 70,
                          work.left + 490, work.top + 590};
    SetWindowPos(window.GetHandle(), nullptr, resized.left, resized.top, 420, 520,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    Check(window_state::Save(window.GetHandle(), path), "Save resize failed");
    Check(window_state::Load(loaded, path) && EqualRect(&loaded, &resized),
          "Resize before closing must retain latest bounds");
    const std::string last_normal = fixture.Read();
    ShowWindow(window.GetHandle(), SW_SHOWMAXIMIZED);
    Check(!window_state::Save(window.GetHandle(), path),
          "Maximization must not overwrite normal bounds");
    ShowWindow(window.GetHandle(), SW_SHOWMINIMIZED);
    Check(!window_state::Save(window.GetHandle(), path),
          "Minimization must not overwrite normal bounds");
    Check(fixture.Read() == last_normal, "Normal bounds were overwritten");
  }

  const char* invalid_states[] = {
      "", "1;2;401;502", "1,2,1,502", "1,2,401,502junk",
      "-2147483648,0,2147483647,500", "100000,100000,100400,100500",
  };
  for (const char* state : invalid_states) {
    fixture.Write(state);
    RECT unchanged = {1, 2, 3, 4};
    loaded = unchanged;
    Check(!window_state::Load(loaded, path), "Invalid state must be rejected");
    Check(EqualRect(&loaded, &unchanged), "Invalid state changed output bounds");
  }

  ProbeWindow window;
  Check(window.Create(L"Write failure test", {10, 10}, {440, 950}),
        "Create write failure window failed");
  window.Show();
  fixture.Write("previous state");
  Check(CreateDirectoryW((path + L".tmp").c_str(), nullptr) != FALSE,
        "Set up write failure failed");
  Check(!window_state::Save(window.GetHandle(), path),
        "Write failure must be reported");
  Check(fixture.Read() == "previous state", "Failed write destroyed prior state");
  Check(RemoveDirectoryW((path + L".tmp").c_str()) != FALSE,
        "Remove write failure fixture failed");
  std::cout << "PASS: save/reopen/resize/normal-state/invalid/write-failure/"
               "initial-monitor DPI ("
            << monitors.size() << " monitors)\n";
}

}  // namespace

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  try {
    Fixture fixture;
    RunTests(fixture);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
