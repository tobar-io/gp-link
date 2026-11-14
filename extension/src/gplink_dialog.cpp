// GP-Link import dialog: building blocks ("Bausteine") + per-track selection and target.
#include "gplink_dialog.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <wchar.h>

void (*gplink_dialog_test_hook)(HWND dlg) = nullptr;

namespace {

const int MAX_OPTS = 16, MAX_TRACKS = 64, MAX_TARGETS = 256;

struct Opt { char key[64]; wchar_t label[128]; bool on; };
struct Target { int idx; wchar_t label[160]; };
struct Track { char key[160]; wchar_t label[160]; wchar_t info[96]; bool on; int target; };

struct State {
  wchar_t title[256];
  int anchor = 1, countin = 0;
  Opt opts[MAX_OPTS]; int nopts = 0;
  Target targets[MAX_TARGETS]; int ntargets = 0;
  Track tracks[MAX_TRACKS]; int ntracks = 0;
  char *out = nullptr; int outsz = 0;
  HFONT font = nullptr, bold = nullptr;
  int dpi = 96;
};

enum {
  ID_ANCHOR = 101, ID_COUNTIN = 102, ID_ALL = 201, ID_NONE = 202,
  ID_OPT0 = 1000, ID_TRK0 = 2000, ID_TGT0 = 3000, ID_INFO0 = 4000, ID_TIMER = 99,
};

void utf8_to_w(const char *s, wchar_t *out, int n)
{
  if (!MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n)) out[0] = 0;
  out[n - 1] = 0;
}

// '&' would become a mnemonic underline in button texts
void escape_amp(const wchar_t *in, wchar_t *out, int n)
{
  int j = 0;
  for (int i = 0; in[i] && j < n - 2; i++) { if (in[i] == L'&') out[j++] = L'&'; out[j++] = in[i]; }
  out[j] = 0;
}

void parse_spec(State &st, const char *spec)
{
  wcscpy(st.title, L"GP-Link");
  const char *p = spec;
  char line[2048];
  while (*p)
  {
    const char *e = strchr(p, '\n');
    size_t len = e ? (size_t)(e - p) : strlen(p);
    if (len >= sizeof(line)) len = sizeof(line) - 1;
    memcpy(line, p, len); line[len] = 0;
    p = e ? e + 1 : p + len;

    char *f[8] = {}; int nf = 0;
    char *q = line;
    while (nf < 8) { f[nf++] = q; char *t = strchr(q, '\t'); if (!t) break; *t = 0; q = t + 1; }

    if (!strcmp(f[0], "title") && nf >= 2) utf8_to_w(f[1], st.title, 256);
    else if (!strcmp(f[0], "anchor") && nf >= 2) st.anchor = atoi(f[1]);
    else if (!strcmp(f[0], "countin") && nf >= 2) st.countin = atoi(f[1]);
    else if (!strcmp(f[0], "opt") && nf >= 4 && st.nopts < MAX_OPTS)
    {
      Opt &o = st.opts[st.nopts++];
      lstrcpynA(o.key, f[1], sizeof(o.key));
      utf8_to_w(f[2], o.label, 128);
      o.on = atoi(f[3]) != 0;
    }
    else if (!strcmp(f[0], "target") && nf >= 3 && st.ntargets < MAX_TARGETS)
    {
      Target &t = st.targets[st.ntargets++];
      t.idx = atoi(f[1]);
      utf8_to_w(f[2], t.label, 160);
    }
    else if (!strcmp(f[0], "track") && nf >= 6 && st.ntracks < MAX_TRACKS)
    {
      Track &t = st.tracks[st.ntracks++];
      lstrcpynA(t.key, f[1], sizeof(t.key));
      utf8_to_w(f[2], t.label, 160);
      utf8_to_w(f[3], t.info, 96);
      t.on = atoi(f[4]) != 0;
      t.target = atoi(f[5]);
    }
  }
}

int opt_index(State &st, const char *key)
{
  for (int i = 0; i < st.nopts; i++) if (!strcmp(st.opts[i].key, key)) return i;
  return -1;
}

int S(State &st, int v) { return MulDiv(v, st.dpi, 96); }

HWND mk(HWND dlg, State &st, const wchar_t *cls, const wchar_t *text, DWORD style, int x, int y, int w, int h, int id, HFONT font = nullptr)
{
  HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, S(st, x), S(st, y), S(st, w), S(st, h),
                           dlg, (HMENU)(INT_PTR)id, (HINSTANCE)GetWindowLongPtrW(dlg, GWLP_HINSTANCE), nullptr);
  SendMessageW(c, WM_SETFONT, (WPARAM)(font ? font : st.font), TRUE);
  return c;
}

void update_enabled(HWND dlg, State &st)
{
  int mi = opt_index(st, "midi");
  bool midi = mi < 0 || IsDlgButtonChecked(dlg, ID_OPT0 + mi) == BST_CHECKED;
  int li = opt_index(st, "lyrics");
  if (li >= 0) EnableWindow(GetDlgItem(dlg, ID_OPT0 + li), midi);
  for (int i = 0; i < st.ntracks; i++)
  {
    bool on = IsDlgButtonChecked(dlg, ID_TRK0 + i) == BST_CHECKED;
    EnableWindow(GetDlgItem(dlg, ID_TRK0 + i), midi);
    EnableWindow(GetDlgItem(dlg, ID_INFO0 + i), midi && on);
    EnableWindow(GetDlgItem(dlg, ID_TGT0 + i), midi && on);
  }
  EnableWindow(GetDlgItem(dlg, ID_ALL), midi);
  EnableWindow(GetDlgItem(dlg, ID_NONE), midi);
}

void build(HWND dlg, State &st)
{
  HDC dc = GetDC(dlg);
  st.dpi = GetDeviceCaps(dc, LOGPIXELSY);
  ReleaseDC(dlg, dc);
  NONCLIENTMETRICSW ncm = { sizeof(ncm) };
  SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
  st.font = CreateFontIndirectW(&ncm.lfMessageFont);
  LOGFONTW lb = ncm.lfMessageFont; lb.lfWeight = FW_SEMIBOLD;
  st.bold = CreateFontIndirectW(&lb);
  SetWindowTextW(dlg, st.title);

  const int W = 660, M = 14;
  int y = M;
  wchar_t buf[64], esc[300];

  // start measure / count-in
  mk(dlg, st, L"STATIC", L"Start bar in REAPER:", SS_NOPREFIX, M, y + 3, 130, 20, -1);
  _snwprintf(buf, 63, L"%d", st.anchor); buf[63] = 0;
  mk(dlg, st, L"EDIT", buf, WS_BORDER | WS_TABSTOP | ES_NUMBER, M + 134, y, 56, 22, ID_ANCHOR);
  mk(dlg, st, L"STATIC", L"Count-in (bars):", SS_NOPREFIX, M + 220, y + 3, 120, 20, -1);
  _snwprintf(buf, 63, L"%d", st.countin); buf[63] = 0;
  mk(dlg, st, L"EDIT", buf, WS_BORDER | WS_TABSTOP | ES_NUMBER, M + 344, y, 44, 22, ID_COUNTIN);
  y += 36;

  // building blocks
  int rows = (st.nopts + 1) / 2;
  int gh = 26 + rows * 24 + 6;
  mk(dlg, st, L"BUTTON", L"Import", BS_GROUPBOX, M, y, W - 2 * M, gh, -1, st.bold);
  for (int i = 0; i < st.nopts; i++)
  {
    int col = i % 2, row = i / 2;
    escape_amp(st.opts[i].label, esc, 300);
    HWND c = mk(dlg, st, L"BUTTON", esc, BS_AUTOCHECKBOX | WS_TABSTOP,
                M + 14 + col * 310, y + 24 + row * 24, 300, 22, ID_OPT0 + i);
    SendMessageW(c, BM_SETCHECK, st.opts[i].on ? BST_CHECKED : BST_UNCHECKED, 0);
  }
  y += gh + 12;

  // tracks
  int th = 48 + st.ntracks * 28 + 8;
  mk(dlg, st, L"BUTTON", L"Tracks (MIDI)", BS_GROUPBOX, M, y, W - 2 * M, th, -1, st.bold);
  mk(dlg, st, L"STATIC", L"Guitar Pro track", SS_NOPREFIX, M + 14, y + 24, 200, 18, -1);
  mk(dlg, st, L"STATIC", L"Instrument", SS_NOPREFIX, M + 222, y + 24, 190, 18, -1);
  mk(dlg, st, L"STATIC", L"Target in REAPER", SS_NOPREFIX, M + 420, y + 24, 190, 18, -1);
  int ty = y + 46;
  for (int i = 0; i < st.ntracks; i++)
  {
    Track &t = st.tracks[i];
    escape_amp(t.label, esc, 300);
    HWND c = mk(dlg, st, L"BUTTON", esc, BS_AUTOCHECKBOX | WS_TABSTOP, M + 14, ty + i * 28, 200, 22, ID_TRK0 + i);
    SendMessageW(c, BM_SETCHECK, t.on ? BST_CHECKED : BST_UNCHECKED, 0);
    mk(dlg, st, L"STATIC", t.info, SS_NOPREFIX | SS_ENDELLIPSIS, M + 222, ty + i * 28 + 3, 192, 20, ID_INFO0 + i);
    HWND cb = mk(dlg, st, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP,
                 M + 420, ty + i * 28 - 1, 198, 300, ID_TGT0 + i);
    int sel = 0;
    SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)L"+ New track");
    SendMessageW(cb, CB_SETITEMDATA, 0, 0);
    for (int k = 0; k < st.ntargets; k++)
    {
      int pos = (int)SendMessageW(cb, CB_ADDSTRING, 0, (LPARAM)st.targets[k].label);
      SendMessageW(cb, CB_SETITEMDATA, pos, st.targets[k].idx);
      if (st.targets[k].idx == t.target) sel = pos;
    }
    SendMessageW(cb, CB_SETCURSEL, sel, 0);
  }
  y += th + 14;

  // buttons
  mk(dlg, st, L"BUTTON", L"All", BS_PUSHBUTTON | WS_TABSTOP, M, y, 70, 28, ID_ALL);
  mk(dlg, st, L"BUTTON", L"None", BS_PUSHBUTTON | WS_TABSTOP, M + 76, y, 70, 28, ID_NONE);
  mk(dlg, st, L"BUTTON", L"Import", BS_DEFPUSHBUTTON | WS_TABSTOP, W - M - 220, y, 110, 28, IDOK);
  mk(dlg, st, L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, W - M - 104, y, 104, 28, IDCANCEL);
  y += 28 + M;

  // size + center over parent
  RECT rc = { 0, 0, S(st, W), S(st, y) };
  AdjustWindowRectEx(&rc, (DWORD)GetWindowLongPtrW(dlg, GWL_STYLE), FALSE, (DWORD)GetWindowLongPtrW(dlg, GWL_EXSTYLE));
  int ww = rc.right - rc.left, wh = rc.bottom - rc.top;
  RECT pr;
  HWND parent = GetParent(dlg);
  if (!parent || !GetWindowRect(parent, &pr)) SystemParametersInfoW(SPI_GETWORKAREA, 0, &pr, 0);
  int x = pr.left + ((pr.right - pr.left) - ww) / 2, yy = pr.top + ((pr.bottom - pr.top) - wh) / 2;
  if (yy < 0) yy = 0;
  SetWindowPos(dlg, nullptr, x, yy, ww, wh, SWP_NOZORDER);
  update_enabled(dlg, st);
}

void append(State &st, const char *fmt, ...)
{
  size_t used = strlen(st.out);
  if ((int)used >= st.outsz - 1) return;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(st.out + used, st.outsz - used, fmt, ap);
  va_end(ap);
}

void collect(HWND dlg, State &st)
{
  st.out[0] = 0;
  BOOL ok;
  int anchor = (int)GetDlgItemInt(dlg, ID_ANCHOR, &ok, FALSE);
  int countin = (int)GetDlgItemInt(dlg, ID_COUNTIN, &ok, FALSE);
  append(st, "ok\t1\nanchor\t%d\ncountin\t%d\n", anchor < 1 ? 1 : anchor, countin < 0 ? 0 : countin);
  for (int i = 0; i < st.nopts; i++)
    append(st, "opt\t%s\t%d\n", st.opts[i].key, IsDlgButtonChecked(dlg, ID_OPT0 + i) == BST_CHECKED ? 1 : 0);
  for (int i = 0; i < st.ntracks; i++)
  {
    HWND cb = GetDlgItem(dlg, ID_TGT0 + i);
    int sel = (int)SendMessageW(cb, CB_GETCURSEL, 0, 0);
    int tgt = sel >= 0 ? (int)SendMessageW(cb, CB_GETITEMDATA, sel, 0) : 0;
    append(st, "track\t%s\t%d\t%d\n", st.tracks[i].key,
           IsDlgButtonChecked(dlg, ID_TRK0 + i) == BST_CHECKED ? 1 : 0, tgt);
  }
}

INT_PTR CALLBACK proc(HWND dlg, UINT msg, WPARAM wp, LPARAM lp)
{
  State *st = (State *)GetWindowLongPtrW(dlg, DWLP_USER);
  switch (msg)
  {
    case WM_INITDIALOG:
      SetWindowLongPtrW(dlg, DWLP_USER, lp);
      st = (State *)lp;
      build(dlg, *st);
      if (gplink_dialog_test_hook) SetTimer(dlg, ID_TIMER, 600, nullptr);
      return TRUE;
    case WM_TIMER:
      if (wp == ID_TIMER) { KillTimer(dlg, ID_TIMER); if (gplink_dialog_test_hook) gplink_dialog_test_hook(dlg); }
      return TRUE;
    case WM_COMMAND:
    {
      int id = LOWORD(wp);
      if (id == IDOK) { collect(dlg, *st); EndDialog(dlg, 1); return TRUE; }
      if (id == IDCANCEL) { EndDialog(dlg, 0); return TRUE; }
      if (id == ID_ALL || id == ID_NONE)
      {
        for (int i = 0; i < st->ntracks; i++) CheckDlgButton(dlg, ID_TRK0 + i, id == ID_ALL ? BST_CHECKED : BST_UNCHECKED);
        update_enabled(dlg, *st);
        return TRUE;
      }
      if (HIWORD(wp) == BN_CLICKED && ((id >= ID_OPT0 && id < ID_OPT0 + MAX_OPTS) || (id >= ID_TRK0 && id < ID_TRK0 + MAX_TRACKS)))
      {
        update_enabled(dlg, *st);
        return TRUE;
      }
      break;
    }
    case WM_DESTROY:
      if (st) { DeleteObject(st->font); DeleteObject(st->bold); }
      break;
  }
  return FALSE;
}

} // namespace

bool gplink_import_dialog(HINSTANCE inst, HWND parent, const char *spec, char *out, int outsz)
{
  State *st = new State();
  parse_spec(*st, spec ? spec : "");
  st->out = out; st->outsz = outsz;
  out[0] = 0;

  // empty in-memory dialog template; controls are created in WM_INITDIALOG
  alignas(4) WORD tmpl[64] = {};
  DLGTEMPLATE *d = (DLGTEMPLATE *)tmpl;
  d->style = DS_MODALFRAME | WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_SETFONT;
  d->cdit = 0; d->x = 0; d->y = 0; d->cx = 300; d->cy = 200;
  WORD *w = (WORD *)(d + 1);
  *w++ = 0;            // no menu
  *w++ = 0;            // default dialog class
  const wchar_t *t = L"GP-Link";
  while (*t) *w++ = *t++;
  *w++ = 0;            // title
  *w++ = 9;            // font size (replaced by system message font in WM_INITDIALOG)
  const wchar_t *fn = L"Segoe UI";
  while (*fn) *w++ = *fn++;
  *w++ = 0;

  INT_PTR r = DialogBoxIndirectParamW(inst, (DLGTEMPLATE *)tmpl, parent, proc, (LPARAM)st);
  delete st;
  return r == 1;
}
