#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

#include <string>

namespace window_state {

// Loads normal bounds in physical screen coordinates. An explicit path lets
// native tests avoid the user's state file; an empty path uses AppData.
bool Load(RECT& out_rect, const std::wstring& path = L"");

// Saves visible normal bounds. Minimization/maximization retain the previous
// normal state, and interrupted writes leave the previous file intact.
bool Save(HWND hwnd, const std::wstring& path = L"");

}  // namespace window_state

#endif  // RUNNER_WINDOW_STATE_H_
