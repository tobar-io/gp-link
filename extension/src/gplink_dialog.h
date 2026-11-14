#pragma once
#include <windows.h>

// GP-Link import dialog (plain Win32, no REAPER dependency).
//
// spec (UTF-8, one entry per line, fields separated by TAB):
//   title  <text>
//   anchor <1-based measure>
//   countin <bars>
//   opt    <key> <label> <0|1>
//   target <index> <label>                       (existing REAPER tracks, index >= 1)
//   track  <key> <label> <info> <0|1> <target>   (target 0 = new track)
//
// result (UTF-8): "ok\t1" + the same lines with the chosen values:
//   anchor <n> / countin <n> / opt <key> <0|1> / track <key> <0|1> <target>
//
// Returns false if cancelled.
bool gplink_import_dialog(HINSTANCE inst, HWND parent, const char *spec, char *out, int outsz);

// test hook: called ~600 ms after the dialog is shown (screenshots / automation)
extern void (*gplink_dialog_test_hook)(HWND dlg);
