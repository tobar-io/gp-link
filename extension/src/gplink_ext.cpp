// GP-Link REAPER extension (reaper_gplink-x64.dll)
//
//  * registers .gp / .gpx / .gp5 (Guitar Pro 5-8) as importable media types, so such a file can be
//    dragged into the arrange view like a WAV. The placeholder item is replaced by the
//    GP-Link import (track mapping dialog, MIDI items, tempo map, section regions).
//  * installs/updates the embedded GP-Link Lua engine in <resource>/Scripts/GP-Link and
//    registers its actions (no manual "Load ReaScript" needed).
//  * native Auto-Sync (toggle action): watches the linked .gp file and re-syncs on save.
//  * menu: Extensions -> GP-Link.
//
// Only plain C function pointers cross the REAPER boundary (no C++ class implemented here),
// so the DLL can be built with any compiler (MSVC, clang, MinGW).

#define REAPERAPI_IMPLEMENT
#define REAPERAPI_MINIMAL
#define REAPERAPI_WANT_PCM_Source_CreateFromType
#define REAPERAPI_WANT_GetMediaItemTake_Source
#define REAPERAPI_WANT_GetProjExtState
#define REAPERAPI_WANT_Main_OnCommand
#define REAPERAPI_WANT_GetPlayState
#define REAPERAPI_WANT_SetExtState
#define REAPERAPI_WANT_GetExtState
#define REAPERAPI_WANT_GetResourcePath
#define REAPERAPI_WANT_DeleteTrackMediaItem
#define REAPERAPI_WANT_GetMediaItem_Track
#define REAPERAPI_WANT_CountMediaItems
#define REAPERAPI_WANT_GetMediaItem
#define REAPERAPI_WANT_GetActiveTake
#define REAPERAPI_WANT_GetMediaItemInfo_Value
#define REAPERAPI_WANT_ShowConsoleMsg
#define REAPERAPI_WANT_EnumProjects
#define REAPERAPI_WANT_RefreshToolbar2
#define REAPERAPI_WANT_UpdateArrange
#define REAPERAPI_WANT_GetSetMediaItemTakeInfo_String
#define REAPERAPI_WANT_AddExtensionsMainMenu
#define REAPERAPI_WANT_RecursiveCreateDirectory
#define REAPERAPI_WANT_GetSetMediaTrackInfo_String
#define REAPERAPI_WANT_CountTrackMediaItems
#define REAPERAPI_WANT_TrackFX_GetCount
#define REAPERAPI_WANT_DeleteTrack

#include <windows.h>
#include <string.h>
#include <stdio.h>
#include "reaper_plugin.h"
#include "reaper_plugin_functions.h"
#include "gplink_embedded.h"
#include "gplink_dialog.h"

static reaper_plugin_info_t *g_rec = nullptr;
static char g_dir[2048];        // <resource>/Scripts/GP-Link/
static int g_cmdImport = 0, g_cmdSync = 0, g_cmdUnlink = 0, g_cmdAutoOnce = 0, g_cmdAutoToggle = 0;
static int g_cmdStructure = 0, g_cmdDialog = 0;
static HINSTANCE g_inst = nullptr;
static bool g_autosync = true;
static bool g_busy = false;

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

static void log_msg(const char *s)
{
  if (ShowConsoleMsg) ShowConsoleMsg(s);
}

static bool to_wide(const char *utf8, wchar_t *out, int outsz)
{
  return MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, outsz) > 0;
}

// .gp (Guitar Pro 7/8), .gpx (6), .gp5 (5)
static bool ends_with_gp(const char *fn)
{
  const char *dot = fn ? strrchr(fn, '.') : nullptr;
  if (!dot) return false;
  return !_stricmp(dot, ".gp") || !_stricmp(dot, ".gpx") || !_stricmp(dot, ".gp5");
}

static const char *base_name(const char *fn)
{
  const char *b = fn;
  for (const char *p = fn; *p; p++) if (*p == '\\' || *p == '/') b = p + 1;
  return b;
}

// read whole file (UTF-8 path). caller frees with free(). returns nullptr if missing.
static char *read_file(const char *path, DWORD *outlen)
{
  wchar_t w[2048];
  if (!to_wide(path, w, 2048)) return nullptr;
  HANDLE h = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return nullptr;
  DWORD sz = GetFileSize(h, nullptr), rd = 0;
  char *buf = (char *)malloc(sz + 1);
  if (buf && ReadFile(h, buf, sz, &rd, nullptr) && rd == sz) { buf[sz] = 0; if (outlen) *outlen = sz; }
  else { free(buf); buf = nullptr; }
  CloseHandle(h);
  return buf;
}

static bool write_file(const char *path, const char *data, size_t len)
{
  wchar_t w[2048];
  if (!to_wide(path, w, 2048)) return false;
  HANDLE h = CreateFileW(w, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return false;
  DWORD wr = 0;
  BOOL ok = WriteFile(h, data, (DWORD)len, &wr, nullptr);
  CloseHandle(h);
  return ok && wr == len;
}

// file "version stamp": last write time + size. 0 if missing.
static unsigned long long file_stamp(const char *path)
{
  wchar_t w[2048];
  WIN32_FILE_ATTRIBUTE_DATA a;
  if (!to_wide(path, w, 2048) || !GetFileAttributesExW(w, GetFileExInfoStandard, &a)) return 0;
  unsigned long long t = ((unsigned long long)a.ftLastWriteTime.dwHighDateTime << 32) | a.ftLastWriteTime.dwLowDateTime;
  return t ^ ((unsigned long long)a.nFileSizeLow << 1);
}

// ---------------------------------------------------------------------------
// embedded Lua engine -> <resource>/Scripts/GP-Link
// ---------------------------------------------------------------------------

static void install_scripts()
{
  snprintf(g_dir, sizeof(g_dir), "%s\\Scripts\\GP-Link\\", GetResourcePath());
  RecursiveCreateDirectory(g_dir, 0);
  char path[2048];
  for (int i = 0; i < GPLINK_EMBEDDED_COUNT; i++)
  {
    const gplink_file &f = GPLINK_EMBEDDED[i];
    snprintf(path, sizeof(path), "%s%s", g_dir, f.name);
    DWORD len = 0;
    char *cur = read_file(path, &len);
    bool same = cur && len == f.len && memcmp(cur, f.data, f.len) == 0;
    bool keep = cur && f.user_editable; // never overwrite the user's config
    free(cur);
    if (!same && !keep && !write_file(path, f.data, f.len))
    {
      char m[2300];
      snprintf(m, sizeof(m), "[GP-Link] Could not write %s.\n", path);
      log_msg(m);
    }
  }
  // files shipped by older versions
  static const char *OBSOLETE[] = { "GP-Link - Panel (Drop-Zone).lua", "GP-Link - Nur Struktur uebernehmen.lua", "LIESMICH.md" };
  for (const char *name : OBSOLETE)
  {
    wchar_t w[2048];
    snprintf(path, sizeof(path), "%s%s", g_dir, name);
    if (to_wide(path, w, 2048)) DeleteFileW(w);
  }
}

static int register_script(const char *file)
{
  char path[2048];
  snprintf(path, sizeof(path), "%s%s", g_dir, file);
  custom_action_register_t ca = { 0, nullptr, path, nullptr };
  return g_rec->Register("custom_action", &ca);
}

// ---------------------------------------------------------------------------
// .gp media type: drop -> placeholder item -> GP-Link import
// ---------------------------------------------------------------------------

struct PendingDrop { PCM_source *src; char file[2048]; DWORD tick; };
static PendingDrop g_pending[8];
static int g_npending = 0;

static PCM_source *gp_CreateFromType(const char *type, int priority) { return nullptr; }

static PCM_source *gp_CreateFromFile(const char *filename, int priority)
{
  if (!ends_with_gp(filename) || !PCM_Source_CreateFromType) return nullptr;
  // placeholder: an empty REAPER MIDI source (REAPER owns and implements it)
  PCM_source *src = PCM_Source_CreateFromType("MIDI");
  if (!src) return nullptr;
  if (g_npending == 8) { memmove(g_pending, g_pending + 1, sizeof(PendingDrop) * 7); g_npending = 7; }
  PendingDrop &p = g_pending[g_npending++];
  p.src = src;
  lstrcpynA(p.file, filename, sizeof(p.file));
  p.tick = GetTickCount();
  return src;
}

static const char *gp_EnumFileExtensions(int i, const char **descptr)
{
  static const char *ext[] = { "GP", "GPX", "GP5" };
  static const char *desc[] = { "Guitar Pro 7/8 (GP-Link)", "Guitar Pro 6 (GP-Link)", "Guitar Pro 5 (GP-Link)" };
  if (i < 0 || i > 2) return nullptr;
  if (descptr) *descptr = desc[i];
  return ext[i];
}

static pcmsrc_register_t g_pcmsrc = { gp_CreateFromType, gp_CreateFromFile, gp_EnumFileExtensions };

static void handle_pending_drops()
{
  if (!g_npending) return;
  ReaProject *proj = EnumProjects(-1, nullptr, 0);
  const int n = CountMediaItems(proj);
  for (int k = 0; k < g_npending; k++)
  {
    PendingDrop &p = g_pending[k];
    const char *bn = base_name(p.file);
    size_t bnlen = strlen(bn);
    bool found = false;
    double pos = 0;
    for (int i = n - 1; i >= 0 && !found; i--)
    {
      MediaItem *it = GetMediaItem(proj, i);
      MediaItem_Take *tk = it ? GetActiveTake(it) : nullptr;
      if (!tk) continue;
      bool match = GetMediaItemTake_Source(tk) == p.src;
      if (!match)
      {
        // fallback: REAPER may have duplicated the source; match by take name
        char name[2048] = "";
        GetSetMediaItemTakeInfo_String(tk, "P_NAME", name, false);
        match = strncmp(name, bn, bnlen) == 0 && (name[bnlen] == 0 || name[bnlen] == '.');
      }
      if (match)
      {
        pos = GetMediaItemInfo_Value(it, "D_POSITION");
        MediaTrack *tr = GetMediaItem_Track(it);
        DeleteTrackMediaItem(tr, it);
        found = true;
        // dropped below the last track: REAPER created a track named after the file -> remove it again
        char tname[2048] = "";
        GetSetMediaTrackInfo_String(tr, "P_NAME", tname, false);
        size_t stem = bnlen;
        const char *dot = strrchr(bn, '.');
        if (dot) stem = (size_t)(dot - bn);
        if (CountTrackMediaItems(tr) == 0 && TrackFX_GetCount(tr) == 0 &&
            strlen(tname) == stem && _strnicmp(tname, bn, stem) == 0)
          DeleteTrack(tr);
      }
    }
    if (found)
    {
      PendingDrop drop = p;
      memmove(g_pending + k, g_pending + k + 1, sizeof(PendingDrop) * (g_npending - k - 1));
      g_npending--;
      k--;
      // only the first dropped .gp is imported; further ones are just removed
      static DWORD last_import = 0;
      if (GetTickCount() - last_import > 1500)
      {
        last_import = GetTickCount();
        char posbuf[64];
        snprintf(posbuf, sizeof(posbuf), "%.10f", pos);
        SetExtState("GPLINK_DROP", "file", drop.file, false);
        SetExtState("GPLINK_DROP", "pos", posbuf, false);
        UpdateArrange();
        if (g_cmdImport) Main_OnCommand(g_cmdImport, 0);
      }
    }
    else if (GetTickCount() - p.tick > 5000)
    {
      // not used for an item (e.g. media explorer preview) -> forget, REAPER owns it
      memmove(g_pending + k, g_pending + k + 1, sizeof(PendingDrop) * (g_npending - k - 1));
      g_npending--;
      k--;
    }
  }
}

// ---------------------------------------------------------------------------
// Auto-sync watcher
// ---------------------------------------------------------------------------

static void autosync_poll()
{
  static DWORD last = 0;
  static char watched[2048] = "";
  static ReaProject *watched_proj = nullptr;
  static char watched_fn[2048] = "";
  static unsigned long long stamp = 0, candidate = 0;
  static bool pending = false;

  DWORD now = GetTickCount();
  if (now - last < 1000) return;
  last = now;

  char projfn_now[2048] = "";
  ReaProject *proj = EnumProjects(-1, projfn_now, sizeof(projfn_now));
  char file[2048] = "";
  GetProjExtState(proj, "GPLINK", "file", file, sizeof(file));
  if (!file[0]) { watched[0] = 0; watched_proj = proj; return; }

  unsigned long long s = file_stamp(file);
  if (!s)
  {
    // stored absolute path missing (other PC / moved Drive folder): try path relative to the project
    char rel[2048] = "", projfn[2048] = "";
    GetProjExtState(proj, "GPLINK", "file_rel", rel, sizeof(rel));
    EnumProjects(-1, projfn, sizeof(projfn));
    char *slash = strrchr(projfn, '\\');
    if (rel[0] && slash)
    {
      slash[1] = 0;
      char alt[4096];
      snprintf(alt, sizeof(alt), "%s%s", projfn, rel);
      s = file_stamp(alt);
    }
  }
  if (proj != watched_proj || strcmp(file, watched) != 0 || strcmp(projfn_now, watched_fn) != 0)
  {
    // new project / file / project saved under a (new) name: let the Lua side check once
    lstrcpynA(watched_fn, projfn_now, sizeof(watched_fn));
    // new project / file: let the Lua side check once (it compares content hashes)
    watched_proj = proj;
    lstrcpynA(watched, file, sizeof(watched));
    stamp = s; candidate = 0;
    pending = true; // also when the stored absolute path is missing (relative path on another PC)
  }
  else if (s && s != stamp)
  {
    if (s == candidate) { stamp = s; candidate = 0; pending = true; } // stable for 2 polls
    else candidate = s;
  }

  if (pending && !(GetPlayState() & 4)) // never while recording
  {
    pending = false;
    if (g_cmdAutoOnce) Main_OnCommand(g_cmdAutoOnce, 0);
  }
}

// ---------------------------------------------------------------------------
// timer, actions, menu
// ---------------------------------------------------------------------------

static void on_timer()
{
  if (g_busy) return; // modal dialogs from Lua keep the timer running
  g_busy = true;
  handle_pending_drops();
  if (g_autosync) autosync_poll();
  g_busy = false;
}

// native import dialog, driven by Lua: spec in ExtState GPLINK_DLG/spec, answer in GPLINK_DLG/result
static void run_import_dialog()
{
  SetExtState("GPLINK_DLG", "result", "", false);
  const char *spec = GetExtState("GPLINK_DLG", "spec");
  if (!spec || !spec[0]) return;
  char *copy = _strdup(spec);  // ExtState pointer may change while the dialog runs
  static char out[65536];
  bool was_busy = g_busy;
  g_busy = true; // no auto-sync / drop handling while the modal dialog is open
  bool ok = gplink_import_dialog(g_inst, g_rec->hwnd_main, copy, out, sizeof(out));
  free(copy);
  g_busy = was_busy;
  SetExtState("GPLINK_DLG", "result", ok ? out : "ok\t0", false);
}

static bool on_action(KbdSectionInfo *sec, int command, int val, int val2, int relmode, HWND hwnd)
{
  if (command && command == g_cmdDialog) { run_import_dialog(); return true; }
  if (command != g_cmdAutoToggle || !g_cmdAutoToggle) return false;
  g_autosync = !g_autosync;
  SetExtState("GPLINK_EXT", "autosync", g_autosync ? "1" : "0", true);
  RefreshToolbar2(0, g_cmdAutoToggle);
  return true;
}

static int on_toggle(int command)
{
  if (command == g_cmdAutoToggle && g_cmdAutoToggle) return g_autosync ? 1 : 0;
  return -1;
}

static void on_menu(const char *menuidstr, HMENU menu, int flag)
{
  if (flag != 0 || strcmp(menuidstr, "Main extensions") != 0) return;
  HMENU sub = CreatePopupMenu();
  if (g_cmdImport) AppendMenuA(sub, MF_STRING, g_cmdImport, "Link Guitar Pro file / map tracks...");
  if (g_cmdStructure) AppendMenuA(sub, MF_STRING, g_cmdStructure, "Import structure only from Guitar Pro...");
  if (g_cmdSync) AppendMenuA(sub, MF_STRING, g_cmdSync, "Sync now");
  if (g_cmdAutoToggle) AppendMenuA(sub, MF_STRING, g_cmdAutoToggle, "Auto-Sync");
  if (g_cmdUnlink) { AppendMenuA(sub, MF_SEPARATOR, 0, nullptr); AppendMenuA(sub, MF_STRING, g_cmdUnlink, "Unlink Guitar Pro file..."); }
  AppendMenuA(menu, MF_POPUP | MF_STRING, (UINT_PTR)sub, "GP-Link");
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
  if (!rec)
  {
    // unload
    if (g_rec)
    {
      g_rec->Register("-timer", (void *)on_timer);
      g_rec->Register("-pcmsrc", &g_pcmsrc);
      g_rec->Register("-hookcommand2", (void *)on_action);
      g_rec->Register("-toggleaction", (void *)on_toggle);
      g_rec->Register("-hookcustommenu", (void *)on_menu);
    }
    return 0;
  }
  if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
  if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0; // REAPER too old
  g_rec = rec;
  g_inst = hInstance;

  const char *as = GetExtState("GPLINK_EXT", "autosync");
  g_autosync = !(as && as[0] == '0');

  install_scripts();
  g_cmdImport = register_script("GP-Link - Import Guitar Pro file.lua");
  g_cmdSync = register_script("GP-Link - Sync now.lua");
  g_cmdUnlink = register_script("GP-Link - Unlink.lua");
  g_cmdAutoOnce = register_script("gplink_autosync_once.lua");
  g_cmdStructure = register_script("GP-Link - Import structure only.lua");

  custom_action_register_t cd = { 0, "GPLINK_IMPORT_DIALOG", "GP-Link: import dialog (internal)", nullptr };
  g_cmdDialog = rec->Register("custom_action", &cd);

  custom_action_register_t ca = { 0, "GPLINK_AUTOSYNC_TOGGLE", "GP-Link: auto-sync on/off", nullptr };
  g_cmdAutoToggle = rec->Register("custom_action", &ca);

  rec->Register("pcmsrc", &g_pcmsrc);
  rec->Register("hookcommand2", (void *)on_action);
  rec->Register("toggleaction", (void *)on_toggle);
  rec->Register("hookcustommenu", (void *)on_menu);
  AddExtensionsMainMenu();
  rec->Register("timer", (void *)on_timer);
  return 1;
}
