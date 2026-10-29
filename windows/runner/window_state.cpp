#include "window_state.h"

#include <shlobj.h>

#include <climits>
#include <cstdint>
#include <fstream>

namespace {

// %APPDATA%\kira\window_state.txt, created on demand.
std::wstring StateFilePath() {
  PWSTR appdata_raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                &appdata_raw))) {
    return std::wstring();
  }
  std::wstring dir(appdata_raw);
  CoTaskMemFree(appdata_raw);
  dir += L"\\kira";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\window_state.txt";
}

bool ReadComma(std::istream& input) {
  char comma = 0;
  return (input >> comma) && comma == ',';
}

}  // namespace

namespace window_state {

bool Load(RECT& out_rect, const std::wstring& path) {
  std::ifstream file(path.empty() ? StateFilePath() : path);
  if (!file.is_open()) {
    return false;
  }

  RECT rect{};
  if (!(file >> rect.left) || !ReadComma(file) || !(file >> rect.top) ||
      !ReadComma(file) || !(file >> rect.right) || !ReadComma(file) ||
      !(file >> rect.bottom)) {
    return false;
  }
  file >> std::ws;
  const int64_t width = static_cast<int64_t>(rect.right) - rect.left;
  const int64_t height = static_cast<int64_t>(rect.bottom) - rect.top;
  if (!file.eof() || width <= 0 || width > LONG_MAX || height <= 0 ||
      height > LONG_MAX) {
    return false;
  }

  // Reject placement on a disconnected monitor rather than opening off-screen.
  const POINT center = {rect.left + static_cast<LONG>(width / 2),
                        rect.top + static_cast<LONG>(height / 2)};
  if (MonitorFromPoint(center, MONITOR_DEFAULTTONULL) == nullptr) {
    return false;
  }
  out_rect = rect;
  return true;
}

bool Save(HWND hwnd, const std::wstring& path) {
  if (hwnd == nullptr || !IsWindowVisible(hwnd) || IsIconic(hwnd) ||
      IsZoomed(hwnd)) {
    return false;
  }
  RECT rect;
  if (!GetWindowRect(hwnd, &rect)) {
    return false;
  }
  const std::wstring destination = path.empty() ? StateFilePath() : path;
  if (destination.empty()) {
    return false;
  }

  const std::wstring temporary = destination + L".tmp";
  std::ofstream file(temporary, std::ios::trunc);
  if (!file.is_open()) {
    return false;
  }
  file << rect.left << ',' << rect.top << ',' << rect.right << ',' << rect.bottom;
  file.close();
  if (!file || !MoveFileExW(temporary.c_str(), destination.c_str(),
                           MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

}  // namespace window_state
