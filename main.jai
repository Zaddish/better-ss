#load "win32_extras.jai";
#load "selection.jai";
#load "capture.jai";
#load "d3d11.jai";
#load "label_cache.jai";
#load "user_messages.jai";
#load "nvapi.jai";
#load "output.jai";
#load "ui.jai";

#import "Basic";
#import "File";
#import "Math";
#import "String";
#import "Windows";
#import "Windows_Utf8";
#import "d3d11";
#import "dxgi";
#import "d3d_compiler";

MAX_WINDOW_ENTRIES :: 512;

WM_TRAYICON        :: WM_USER + 1;
WM_MODIFIERCHANGED :: WM_USER + 2;

IDM_QUIT    :: 1001;
IDM_STARTUP :: 1002;

REGISTRY_KEY_PATH :: "Software\\BetterSS";
STARTUP_KEY_PATH  :: "Software\\Microsoft\\Windows\\CurrentVersion\\Run";

// utf8 -> null terminated [] u16. returning a slice (not *u16) lets the jai
// compiler bake the data into the final binary's data segment; a raw pointer
// literal would not survive from comp time into runtime
bake_wide :: (s: string) -> [] u16 {
    w, ok, count_bytes := utf8_to_wide(s);
    assert(ok);
    result: [] u16;
    result.data  = w;
    result.count = count_bytes / 2 + 1;  // include the null terminator
    return result;
}

// ascii -> null terminated [] u8
// return a slice so jai bakes it
bake_cstr :: (s: string) -> [] u8 {
    buf := cast(*u8) alloc(s.count + 1);
    memcpy(buf, s.data, s.count);
    buf[s.count] = 0;
    result: [] u8;
    result.data  = buf;
    result.count = s.count + 1;
    return result;
}

// runtime utf8 -> wide on the temporary allocator. oneshot, for strings we
// can't bake (composed from dynamic data)
temp_wide :: inline (s: string) -> *u16 {
    wide, _, _ := utf8_to_wide(s,, temp);
    return wide;
}

// every jai generated COM interface derives from IUnknown via a chain of
// `#as using X: Parent;` first members. com_release_all walks a structs
// members at comptime and emits safe_release_and_reset for each field
// whose type transitively inherits from IUnknown. non COM fields are skipped
com_release_all :: (s: *$T) #expand {
    #insert #run generate_com_release_body(type_info(T));
}

generate_com_release_body :: (info: *Type_Info_Struct) -> string {
    // reverse declaration so last created released first, so foundational
    // handles (device, context) go out last
    // i think this matches D3D11 cleanup convention?
    b: String_Builder;
    for < member: info.members {
        if !is_com_interface_pointer(member.type) continue;
        print_to_builder(*b, "safe_release_and_reset(*s.%);\n", member.name);
    }
    return builder_to_string(*b);
}

is_com_interface_pointer :: (ti: *Type_Info) -> bool {
    if ti.type != .POINTER return false;
    p := cast(*Type_Info_Pointer) ti;
    if !p.pointer_to || p.pointer_to.type != .STRUCT return false;
    return is_com_interface_struct(cast(*Type_Info_Struct) p.pointer_to);
}

is_com_interface_struct :: (ps: *Type_Info_Struct) -> bool {
    if ps.name == "IUnknown" return true;
    if ps.members.count == 0 return false;
    first := ps.members[0];
    if first.type.type != .STRUCT return false;
    return is_com_interface_struct(cast(*Type_Info_Struct) first.type);
}

REGISTRY_KEY_PATH_W   :: #run bake_wide(REGISTRY_KEY_PATH);
STARTUP_KEY_PATH_W    :: #run bake_wide(STARTUP_KEY_PATH);
W_BETTERSS            :: #run bake_wide("BetterSS");
W_CLASS_HOTKEY_DIALOG :: #run bake_wide("BetterSSHotkeyDialog");
W_CLASS_OVERLAY       :: #run bake_wide("BetterSSOverlay");
W_MENU_STARTUP        :: #run bake_wide("Start with Windows");
W_MENU_QUIT           :: #run bake_wide("Quit");
W_EXT_PNG             :: #run bake_wide("png");
W_REG_GLOBAL_FLAG     :: #run bake_wide("IsGlobal");
W_REG_GLOBAL_TOOL     :: #run bake_wide("GlobalTool");
W_REG_LINE_TOOL       :: #run bake_wide("LineTool");
W_REG_HIGHLIGHT_TOOL  :: #run bake_wide("HighlightTool");
W_REG_CENSOR_TOOL     :: #run bake_wide("CensorTool");

// for now load_settings refuses to read the tool blobs when the stored version disagrees and
// resets to DEFAULT_PER_MODE instead of returning garbage  
// TODO(zaddish): need to make this better for the userd
CONFIG_VERSION         :: 1;
W_REG_CONFIG_VERSION   :: #run bake_wide("ConfigVersion");

Hotkey_Binding :: struct {
    mods: u32;
    vk:   u32;
}

Window_Entry :: struct {
    hwnd:         HWND;
    snap_bounds:  RECT;
}

Capture_Mode :: enum u32 #specified {
    CLIPBOARD :: 0;
    FILE      :: 1;
}

// everything that touches a slot reads from this table or is generated from it below
Hotkey_Spec :: struct {
    idm:            u32;
    mode:           Capture_Mode;
    reg_name_w:     [] u16;     // wstring for Reg*ValueExW value name
    menu_label:     string;     // composed into "% (<keycombo>)..." at menu time
    dialog_title_w: [] u16;     // wstring for the change hotkey dialog
    default_mods:   u32;
    default_vk:     u32;
}

HOTKEY_SPECS :: Hotkey_Spec.[
    .{
        idm            = 1003,
        mode           = .CLIPBOARD,
        reg_name_w     = #run bake_wide("CaptureHotkey"),
        menu_label     = "Capture Hotkey",
        dialog_title_w = #run bake_wide("Set Capture Hotkey"),
        default_mods   = MOD_CONTROL | MOD_SHIFT,
        default_vk     = #char "S",
    },
    .{
        idm            = 1004,
        mode           = .FILE,
        reg_name_w     = #run bake_wide("SaveHotkey"),
        menu_label     = "Save Hotkey",
        dialog_title_w = #run bake_wide("Set Save Hotkey"),
        default_mods   = MOD_CONTROL | MOD_SHIFT | MOD_ALT,
        default_vk     = #char "S",
    },
];

HOTKEY_COUNT :: HOTKEY_SPECS.count;

// emit `IDM_HOTKEY_<i> : u32 : <idm>;` so WM_COMMAND cases can use
// them as constant expr
#insert #run () -> string {
    b: String_Builder;
    for HOTKEY_SPECS {
        print_to_builder(*b, "IDM_HOTKEY_% : u32 : %;\n", it_index, it.idm);
    }
    return builder_to_string(*b);
}();

overlay_window: HWND;
renderer:      Betterss_Renderer;
capture:       Capture_State;
selection:     Selection_State;
nvapi:         Nv_Capture;

is_capturing: bool;
capture_mode: Capture_Mode;

hotkey_storage: [HOTKEY_COUNT] Hotkey_Binding;

tray_icon: NOTIFYICONDATAW;

keyboard_hook:        HHOOK;
hotkey_dialog:        HWND;
hotkey_dialog_slot:   s32;
hotkey_dialog_pending: Hotkey_Binding;
hotkey_dialog_has_pending: bool;
hotkey_dialog_conflict: bool;

cursor_arrow:    HCURSOR;
cursor_cross:    HCURSOR;
cursor_size_all: HCURSOR;

set_mode_cursor :: () {
    if panel_state.is_open  SetCursor(cursor_arrow);
    else                    SetCursor(ifx selection.annotation_mode == .CENSOR then cursor_cross else null);
}

wic_factory: *IWICImagingFactory;

window_entries:  [] Window_Entry;
last_snap_entry: *Window_Entry;
last_mouse_x:       s32;
last_mouse_y:       s32;
snap_enabled:       bool;
snap_held_mods:     u32;
live_mods:          u32;

capture_arena: Flat_Pool;

// pushed into #c_call callbacks
callback_context: #Context;

// filter sections separated by \0, buffer ends in \0\0
// baked at comptime so the double null terminated blob ships in the binary
// idk if this is the best way to do this
bake_save_filter :: () -> [] u16 {
    PARTS :: string.["PNG Files", "*.png", "All Files", "*.*"];
    total := 1;
    for part: PARTS total += part.count + 1;
    buf := cast(*u16) alloc(total * size_of(u16));
    idx := 0;
    for part: PARTS {
        for ch: cast([] u8) part { buf[idx] = cast(u16) ch; idx += 1; }
        buf[idx] = 0; idx += 1;
    }
    buf[idx] = 0;
    result: [] u16;
    result.data  = buf;
    result.count = total;
    return result;
}
W_SAVE_FILTER :: #run bake_save_filter();

main :: () {
    callback_context = context;

    CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    prevent_windows_dpi_scaling();

    init(*capture_arena, 64 * 1024 * 1024);

    cursor_arrow    = LoadCursorW(null, cast(*s16) IDC_ARROW);
    cursor_cross    = LoadCursorW(null, cast(*s16) IDC_CROSS);
    cursor_size_all = LoadCursorW(null, cast(*s16) IDC_SIZEALL);

    CoCreateInstance(*CLSID_WIC_IMAGING_FACTORY, null, CLSCTX_INPROC_SERVER,
                     *IID_WIC_IMAGING_FACTORY, xx *wic_factory);

    load_settings();

    instance := cast(HINSTANCE) GetModuleHandleW(null);

    overlay_window = create_overlay_window(instance);
    if !overlay_window fatal_startup("Could not create overlay window.");

    hotkey_wc: WNDCLASSEXW;
    hotkey_wc.cbSize        = size_of(WNDCLASSEXW);
    hotkey_wc.lpfnWndProc   = xx hotkey_dialog_proc;
    hotkey_wc.hInstance     = instance;
    hotkey_wc.hCursor       = cursor_arrow;
    hotkey_wc.lpszClassName = W_CLASS_HOTKEY_DIALOG.data;
    RegisterClassExW(*hotkey_wc);

    renderer = acquire_renderer(overlay_window);
    if !renderer_is_valid(*renderer) fatal_startup("D3D11 device creation failed. No hardware or WARP device available.");
    if !initialize_shaders(*renderer) fatal_startup("D3D11 resource creation failed.");

    create_tray_icon(instance);

    // if NVAPI is not available show_overlay just falls back to DXGI
    init_nv_capture(*nvapi, renderer.device);

    // DXGI is lazy, it can fail transiently and the
    // hotkey handler already knows how to refresh and retry! yay!

    ShowWindow(overlay_window, SW_HIDE);

    register_keyboard_hook();

    msg: MSG;
    while GetMessageW(*msg, null, 0, 0) {
        TranslateMessage(*msg);
        DispatchMessageW(*msg);
    }

    // the tray icon persists in the shell cache until the next refresh, so remove it
    // explicitly. everything else is process memory, handles, and driver state that
    // the OS reclaims on exit
    remove_tray_icon();

    ExitProcess(0);
}

fatal_startup :: (msg: string) {
    MessageBoxW(null, temp_wide(msg), W_BETTERSS.data, MB_ICONERROR | MB_OK);
    ExitProcess(1);
}

prevent_windows_dpi_scaling :: () {
    // SetProcessDpiAwarenessContext is Win10 1703+, so resolve at runtime
    // and just default back to the old single DPI call on anything older
    // this will probably bite me
    user32 := LoadLibraryA("user32.dll");
    if !user32 return;

    set_ctx := cast(#type (value: DPI_AWARENESS_CONTEXT) -> BOOL #c_call)
        GetProcAddress(user32, "SetProcessDpiAwarenessContext");
    if set_ctx {
        set_ctx(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    } else {
        SetProcessDPIAware();
    }
}

save_settings :: () {
    key: HKEY;
    if RegCreateKeyExW(HKEY_CURRENT_USER, REGISTRY_KEY_PATH_W.data, 0, null, 0, KEY_WRITE, null, *key, null) == ERROR_SUCCESS {
        version: u32 = CONFIG_VERSION;
        RegSetValueExW(key, W_REG_CONFIG_VERSION.data, 0, REG_DWORD, xx *version, size_of(u32));

        for * hotkey_storage {
            RegSetValueExW(key, HOTKEY_SPECS[it_index].reg_name_w.data, 0, REG_BINARY, xx it, size_of(Hotkey_Binding));
        }
        panel_save_active();
        global_flag: u32 = xx panel_state.is_global;
        RegSetValueExW(key, W_REG_GLOBAL_FLAG.data,  0, REG_BINARY, xx *global_flag, size_of(u32));
        RegSetValueExW(key, W_REG_GLOBAL_TOOL.data,  0, REG_BINARY, xx *panel_state.global_settings, size_of(Tool_Settings));
        RegSetValueExW(key, W_REG_LINE_TOOL.data,      0, REG_BINARY, xx *panel_state.per_mode[0], size_of(Tool_Settings));
        RegSetValueExW(key, W_REG_HIGHLIGHT_TOOL.data, 0, REG_BINARY, xx *panel_state.per_mode[1], size_of(Tool_Settings));
        RegSetValueExW(key, W_REG_CENSOR_TOOL.data,    0, REG_BINARY, xx *panel_state.per_mode[2], size_of(Tool_Settings));
        RegCloseKey(key);
    }
}

load_settings :: () {
    for * hotkey_storage {
        it.mods = HOTKEY_SPECS[it_index].default_mods;
        it.vk   = HOTKEY_SPECS[it_index].default_vk;
    }

    key: HKEY;
    opened := RegOpenKeyExW(HKEY_CURRENT_USER, REGISTRY_KEY_PATH_W.data, 0, KEY_READ, *key) == ERROR_SUCCESS;
    if !opened {
        panel_sync_active();
        return;
    }
    defer RegCloseKey(key);

    version:      u32;
    version_size: u32 = size_of(u32);
    version_ok := RegQueryValueExW(key, W_REG_CONFIG_VERSION.data, null, null, xx *version, *version_size) == ERROR_SUCCESS
                  && version_size == size_of(u32)
                  && version     == CONFIG_VERSION;

    for * hotkey_storage {
        size: u32 = size_of(Hotkey_Binding);
        if RegQueryValueExW(key, HOTKEY_SPECS[it_index].reg_name_w.data, null, null, xx it, *size) != ERROR_SUCCESS
           || size != size_of(Hotkey_Binding) {
            it.mods = HOTKEY_SPECS[it_index].default_mods;
            it.vk   = HOTKEY_SPECS[it_index].default_vk;
        }
    }

    if !version_ok {
        // tool settings / panel state may be in an older layout
        // Im just leaving comptime DEFAULT_PER_MODE literal in the panel state
        // and warning the user, then rewrite the registry in the current layout
        user_message_warning("settings reset after update");
        panel_sync_active();
        save_settings();
        return;
    }

    global_flag: u32;
    flag_size: u32 = size_of(u32);
    if RegQueryValueExW(key, W_REG_GLOBAL_FLAG.data, null, null, xx *global_flag, *flag_size) == ERROR_SUCCESS
       && flag_size == size_of(u32) {
        panel_state.is_global = cast(bool) global_flag;
    }

    // stage into a scratch copy so a partial failure halfway
    // through cannot leave panel_state in a weird state
    scratch_global: Tool_Settings;
    scratch_modes:  [MODE_COUNT] Tool_Settings;

    blobs_ok := true;
    blobs_ok = blobs_ok && load_tool_blob(key, W_REG_GLOBAL_TOOL.data,    *scratch_global);
    blobs_ok = blobs_ok && load_tool_blob(key, W_REG_LINE_TOOL.data,      *scratch_modes[0]);
    blobs_ok = blobs_ok && load_tool_blob(key, W_REG_HIGHLIGHT_TOOL.data, *scratch_modes[1]);
    blobs_ok = blobs_ok && load_tool_blob(key, W_REG_CENSOR_TOOL.data,    *scratch_modes[2]);

    if blobs_ok {
        panel_state.global_settings = scratch_global;
        panel_state.per_mode        = scratch_modes;
    } else {
        user_message_warning("settings reset after update");
        save_settings();
    }

    panel_sync_active();
}

load_tool_blob :: (key: HKEY, name_w: *u16, out: *Tool_Settings) -> bool {
    size: u32 = size_of(Tool_Settings);
    status := RegQueryValueExW(key, name_w, null, null, xx out, *size);
    return status == ERROR_SUCCESS && size == size_of(Tool_Settings);
}

is_startup_enabled :: () -> bool {
    key: HKEY;
    result := false;
    if RegOpenKeyExW(HKEY_CURRENT_USER, STARTUP_KEY_PATH_W.data, 0, KEY_READ, *key) == ERROR_SUCCESS {
        if RegQueryValueExW(key, W_BETTERSS.data, null, null, null, null) == ERROR_SUCCESS {
            result = true;
        }
        RegCloseKey(key);
    }
    return result;
}

set_startup_enabled :: (enable: bool) {
    key: HKEY;
    if RegOpenKeyExW(HKEY_CURRENT_USER, STARTUP_KEY_PATH_W.data, 0, KEY_WRITE, *key) != ERROR_SUCCESS return;
    defer RegCloseKey(key);

    if enable {
        exe_path_buf: [MAX_PATH] u16;
        len := GetModuleFileNameW(null, exe_path_buf.data, exe_path_buf.count);
        exe_path, _ := wide_to_utf8(exe_path_buf.data, len,, temp);

        // quote the exe path so spaces dont break the run entry
        quoted := tprint("\"%\"", exe_path);
        wide   := temp_wide(quoted);
        wide_len: u32 = 0;
        while wide[wide_len] != 0  wide_len += 1;
        byte_count := (wide_len + 1) * 2;
        RegSetValueExW(key, W_BETTERSS.data, 0, REG_SZ, xx wide, byte_count);
    } else {
        RegDeleteValueW(key, W_BETTERSS.data);
    }
}

get_hotkey_string :: (h: *Hotkey_Binding) -> string {
    builder: String_Builder;
    if h.mods & MOD_CONTROL append(*builder, "Ctrl+");
    if h.mods & MOD_SHIFT   append(*builder, "Shift+");
    if h.mods & MOD_ALT     append(*builder, "Alt+");
    if h.mods & MOD_WIN     append(*builder, "Win+");

    key_buf: [32] u16;
    scan_code := MapVirtualKeyW(h.vk, MAPVK_VK_TO_VSC);
    GetKeyNameTextW(cast(s32) (scan_code << 16), key_buf.data, key_buf.count);
    if key_buf[0] != 0 {
        name, _ := wide_to_utf8(key_buf.data,, temp);
        append(*builder, name);
    }
    return builder_to_string(*builder);
}

modifier_from_vk :: (vk: u32) -> u32 {
    if vk == VK_SHIFT   || vk == VK_LSHIFT   || vk == VK_RSHIFT   return MOD_SHIFT;
    if vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL return MOD_CONTROL;
    if vk == VK_MENU    || vk == VK_LMENU    || vk == VK_RMENU    return MOD_ALT;
    if vk == VK_LWIN    || vk == VK_RWIN                          return MOD_WIN;
    return 0;
}

hotkey_matches :: (h: *Hotkey_Binding, vk: u32, mods: u32) -> bool {
    return vk == h.vk && mods == h.mods;
}

register_keyboard_hook :: () {
    if keyboard_hook {
        UnhookWindowsHookEx(keyboard_hook);
        keyboard_hook = null;
    }
    keyboard_hook = SetWindowsHookExW(WH_KEYBOARD_LL, low_level_keyboard_proc,
                                      cast(HINSTANCE) GetModuleHandleW(null), 0);
}

low_level_keyboard_proc :: (code: s32, wparam: WPARAM, lparam: LPARAM) -> LRESULT #c_call {
    if code < 0 return CallNextHookEx(null, code, wparam, lparam);

    push_context callback_context {
        kbd := cast(*KBDLLHOOKSTRUCT) cast(*void) lparam;
        vk := kbd.vkCode;
        modifier := modifier_from_vk(vk);

        if modifier {
            if wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN {
                live_mods |= modifier;
            } else if wparam == WM_KEYUP || wparam == WM_SYSKEYUP {
                live_mods &= ~modifier;
            }
            if is_capturing PostMessageW(overlay_window, WM_MODIFIERCHANGED, 0, 0);
            return CallNextHookEx(keyboard_hook, code, wparam, lparam);
        }

        if wparam != WM_KEYDOWN && wparam != WM_SYSKEYDOWN {
            return CallNextHookEx(keyboard_hook, code, wparam, lparam);
        }

        if hotkey_dialog {
            // NOTE(zaddish): swallow Win+* from the OS while binding; otherwise
            // Win+Shift+S launches Snipping Tool, steals focus, and our
            // WM_KILLFOCUS handler collapses the dialog. repost so the dialog
            // still gets the key
            // this is not the right thing to do
            if live_mods & MOD_WIN {
                PostMessageW(hotkey_dialog, cast(u32) wparam, cast(WPARAM) vk, 0);
                return 1;
            }
            return CallNextHookEx(keyboard_hook, code, wparam, lparam);
        }

        if is_capturing {
            if panel_state.text_editing {
                // let all keys through to TranslateMessage so WM_CHAR fires
                // VERY hacky. need to figure out this dumb windowskey shift S shit snipping tool does
                return CallNextHookEx(keyboard_hook, code, wparam, lparam);
            }

            if vk == VK_ESCAPE {
                PostMessageW(overlay_window, WM_KEYDOWN, VK_ESCAPE, 0);
                return 1;
            }
            if live_mods == 0 && vk >= #char "1" && vk <= #char "3" {
                PostMessageW(overlay_window, WM_KEYDOWN, cast(WPARAM) vk, 0);
                return 1;
            }
            if vk == VK_TAB {
                PostMessageW(overlay_window, WM_KEYDOWN, VK_TAB, 0);
                return 1;
            }
        } else {
            for * hotkey_storage {
                if hotkey_matches(it, vk, live_mods) {
                    capture_mode = HOTKEY_SPECS[it_index].mode;
                    PostMessageW(overlay_window, WM_HOTKEY, 0, 0);
                    return 1;
                }
            }
        }

        return CallNextHookEx(keyboard_hook, code, wparam, lparam);
    }
}

update_tray_tip :: () {
    builder: String_Builder;
    print_to_builder(*builder, "BetterSS %", BUILD_GIT_HASH);
    for HOTKEY_SPECS {
        print_to_builder(*builder, "\n%: %", it.menu_label, get_hotkey_string(*hotkey_storage[it_index]));
    }
    copy_utf8_to_wide_buffer(*tray_icon.szTip, builder_to_string(*builder,, temp));
}

create_tray_icon :: (instance: HINSTANCE) {
    tray_icon.cbSize           = size_of(NOTIFYICONDATAW);
    tray_icon.hWnd             = overlay_window;
    tray_icon.uID              = 1;
    tray_icon.uFlags           = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    tray_icon.uCallbackMessage = WM_TRAYICON;

   cx := GetSystemMetrics(SM_CXSMICON);
    cy := GetSystemMetrics(SM_CYSMICON);
    tray_icon.hIcon = cast(HICON) LoadImageW(instance, MAKEINTRESOURCEW(2), IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR | LR_SHARED);
    if !tray_icon.hIcon {
        tray_icon.hIcon = LoadIconW(null, MAKEINTRESOURCEW(IDI_APPLICATION));
    }
    defer user_message_flush_pending();
    update_tray_tip();
    Shell_NotifyIconW(NIM_ADD, *tray_icon);
}

remove_tray_icon :: () {
    Shell_NotifyIconW(NIM_DELETE, *tray_icon);
}

append_hotkey_menu_item :: (menu: HMENU, id: u32, label: string, h: *Hotkey_Binding) {
    text := tprint("% (%)...", label, get_hotkey_string(h));
    AppendMenuW(menu, MF_STRING, id, temp_wide(text));
}

show_tray_menu :: () {
    menu := CreatePopupMenu();
    defer DestroyMenu(menu);

    version_label := tprint("BetterSS %", BUILD_GIT_HASH);
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, temp_wide(version_label));
    AppendMenuW(menu, MF_SEPARATOR, 0, null);

    for HOTKEY_SPECS {
        append_hotkey_menu_item(menu, it.idm, it.menu_label, *hotkey_storage[it_index]);
    }

    startup_flag: u32 = MF_STRING;
    if is_startup_enabled() startup_flag |= MF_CHECKED;
    AppendMenuW(menu, startup_flag, IDM_STARTUP, W_MENU_STARTUP.data);

    AppendMenuW(menu, MF_SEPARATOR, 0, null);
    AppendMenuW(menu, MF_STRING, IDM_QUIT, W_MENU_QUIT.data);

    pt: POINT;
    GetCursorPos(*pt);
    SetForegroundWindow(overlay_window);
    SetCursor(cursor_arrow);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, overlay_window, null);
    PostMessageW(overlay_window, WM_NULL, 0, 0);
}

hotkey_dialog_proc :: (window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT #c_call {
    push_context callback_context {
        if message == {
            case WM_KEYDOWN; #through;
            case WM_SYSKEYDOWN; {
                vk := cast(u32) wparam;
                if modifier_from_vk(vk) return DefWindowProcW(window, message, wparam, lparam);

                if vk == VK_ESCAPE {
                    DestroyWindow(window);
                    return 0;
                }

                if vk == VK_RETURN {
                    if !hotkey_dialog_has_pending return 0;
                    for * hotkey_storage {
                        if it_index == hotkey_dialog_slot continue;
                        if it.vk == hotkey_dialog_pending.vk && it.mods == hotkey_dialog_pending.mods {
                            hotkey_dialog_conflict = true;
                            InvalidateRect(window, null, xx BOOL.TRUE);
                            return 0;
                        }
                    }
                    hotkey_storage[hotkey_dialog_slot] = hotkey_dialog_pending;
                    save_settings();
                    update_tray_tip();
                    Shell_NotifyIconW(NIM_MODIFY, *tray_icon);
                    DestroyWindow(window);
                    return 0;
                }

                hotkey_dialog_pending.vk   = vk;
                hotkey_dialog_pending.mods = live_mods;
                hotkey_dialog_has_pending  = true;
                hotkey_dialog_conflict     = false;
                InvalidateRect(window, null, xx BOOL.TRUE);
                return 0;
            }

            case WM_KILLFOCUS; {
                PostMessageW(window, WM_CLOSE, 0, 0);
                return 0;
            }

            case WM_CLOSE; {
                DestroyWindow(window);
                return 0;
            }

            case WM_DESTROY; {
                hotkey_dialog             = null;
                hotkey_dialog_has_pending = false;
                hotkey_dialog_conflict    = false;
                return 0;
            }

            case WM_PAINT; {
                ps: PAINTSTRUCT;
                dc := BeginPaint(window, *ps);
                rect: RECT;
                GetClientRect(window, *rect);
                FillRect(dc, *rect, COLOR_WINDOW_BRUSH);
                SetBkMode(dc, TRANSPARENT);

                line: string;
                if hotkey_dialog_has_pending {
                    key_str := get_hotkey_string(*hotkey_dialog_pending);
                    if hotkey_dialog_conflict {
                        line = tprint("Conflicts: %", key_str);
                    } else {
                        line = tprint("%    (Enter to confirm, Esc to cancel)", key_str);
                    }
                } else {
                    line = "Press a key combination, then Enter. Esc cancels.";
                }
                DrawTextW(dc, temp_wide(line), -1, *rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
                EndPaint(window, *ps);
                return 0;
            }
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }
}

show_hotkey_dialog :: (instance: HINSTANCE, slot: s32) {
    if hotkey_dialog return;
    if slot < 0 || slot >= HOTKEY_COUNT return;

    width  : s32 = 420;
    height : s32 = 120;
    x := (GetSystemMetrics(SM_CXSCREEN) - width)  / 2;
    y := (GetSystemMetrics(SM_CYSCREEN) - height) / 2;

    hotkey_dialog_slot = slot;
    hotkey_dialog_has_pending = false;
    hotkey_dialog_conflict = false;

    window := CreateWindowExW(xx (WS_EX_TOPMOST | WS_EX_TOOLWINDOW),
        W_CLASS_HOTKEY_DIALOG.data, HOTKEY_SPECS[slot].dialog_title_w.data,
        WS_POPUP | WS_BORDER | WS_CAPTION,
        x, y, width, height, null, null, instance, null);
    if !window return;

    hotkey_dialog = window;
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);
    SetFocus(window);
}

create_overlay_window :: (instance: HINSTANCE) -> HWND {
    wc: WNDCLASSEXW;
    wc.cbSize        = size_of(WNDCLASSEXW);
    wc.style         = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc   = xx window_proc;
    wc.hInstance     = instance;
    wc.hCursor       = null;
    wc.lpszClassName = W_CLASS_OVERLAY.data;
    RegisterClassExW(*wc);

    x := GetSystemMetrics(SM_XVIRTUALSCREEN);
    y := GetSystemMetrics(SM_YVIRTUALSCREEN);
    w := GetSystemMetrics(SM_CXVIRTUALSCREEN);
    h := GetSystemMetrics(SM_CYVIRTUALSCREEN);

    ex_style : s32 = xx (WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP);
    style    : u32 = WS_POPUP;

    window := CreateWindowExW(ex_style, wc.lpszClassName, W_BETTERSS.data,
                              style, x, y, w, h, null, null, instance, null);

    if window {
        disable_transitions: BOOL = .TRUE;
        DwmSetWindowAttribute(window, DWMWA_TRANSITIONS_FORCEDISABLED,
                              xx *disable_transitions, size_of(BOOL));
    }

    return window;
}

rect_offset :: (r: RECT, dx: s32, dy: s32) -> RECT {
    out := r;
    out.left   += dx;
    out.top    += dy;
    out.right  += dx;
    out.bottom += dy;
    return out;
}

collect_window_entries :: (hwnd: HWND, lparam: LPARAM) -> BOOL #c_call {
    push_context callback_context {
        if window_entries.count >= MAX_WINDOW_ENTRIES return .FALSE;
        if hwnd == overlay_window                     return .TRUE;
        if IsWindowVisible(hwnd) == .FALSE            return .TRUE;

        ex_style := GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if ex_style & WS_EX_TOOLWINDOW return .TRUE;

        cloaked: BOOL;
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, xx *cloaked, size_of(BOOL));
        if cloaked == .TRUE return .TRUE;

        snap_bounds: RECT;
        hr := DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, xx *snap_bounds, size_of(RECT));
        if FAILED(hr) GetWindowRect(hwnd, *snap_bounds);
        if snap_bounds.right <= snap_bounds.left || snap_bounds.bottom <= snap_bounds.top return .TRUE;

        // skip borderless/titleless windows unless marked as a top level app
        if GetWindowTextLengthW(hwnd) == 0 && !(ex_style & WS_EX_APPWINDOW) return .TRUE;

        entry := window_entries.data + window_entries.count;
        entry.hwnd        = hwnd;
        entry.snap_bounds = rect_offset(snap_bounds, -capture.virtual_screen.left, -capture.virtual_screen.top);
        window_entries.count += 1;
        return .TRUE;
    }
}

find_window_entry_at_point :: (entries: [] Window_Entry, x: s32, y: s32) -> *Window_Entry {
    for * e: entries {
        if x >= e.snap_bounds.left && x < e.snap_bounds.right &&
           y >= e.snap_bounds.top  && y < e.snap_bounds.bottom {
            return e;
        }
    }
    return null;
}

update_snap_enabled :: () {
    // snap only turns on once the user releases the mods they were already holding
    // when the overlay came up otherwise hitting the hotkey with shift held
    // would immediately snap to a window you werent pointing at
    if !snap_enabled && (live_mods & snap_held_mods) == 0 {
        snap_enabled = true;
    }
}

update_snap_preview :: (mouse_x: s32, mouse_y: s32) {
    current := selection_get_rect(*selection);
    if live_mods & MOD_SHIFT {
        hit := last_snap_entry;
        if !hit || mouse_x < hit.snap_bounds.left || mouse_x >= hit.snap_bounds.right ||
           mouse_y < hit.snap_bounds.top  || mouse_y >= hit.snap_bounds.bottom {
            hit = find_window_entry_at_point(window_entries, mouse_x, mouse_y);
            last_snap_entry = hit;
        }
        if hit {
            target := hit.snap_bounds;
            if current.left != target.left || current.top != target.top ||
               current.right != target.right || current.bottom != target.bottom {
                selection_set_rect(*selection, target);
                refresh_overlay();
            }
            return;
        }
    } else {
        last_snap_entry = null;
    }

    if current.right > current.left || current.bottom > current.top {
        selection_set_rect(*selection, RECT.{});
        refresh_overlay();
    }
}

show_overlay :: () {
    // the swap chain lives for the whole window lifetime, see acquire_renderer
    if !renderer.device {
        renderer = acquire_renderer(overlay_window);
        if !renderer_is_valid(*renderer) return;
        if !initialize_shaders(*renderer) return;
        release_duplications(*capture);
    }

    captured_ok := false;

    if nvapi.is_available {
        refresh_nv_monitors(*nvapi);
        captured_ok = nv_capture_all_monitors(*nvapi, renderer.device);
        if captured_ok {
            capture.virtual_screen = nvapi.virtual_screen;
            cache_nv_background(*renderer, *nvapi);
        }
    }

    if !captured_ok {
        if !capture_is_valid(*capture) {
            if !refresh_capture_state(*capture, renderer.device) return;
        }

        // on access lost, refresh the capture state and retry once
        capture_result := capture_all_monitors(*capture);
        if capture_result == -1 {
            release_duplications(*capture);
            if !refresh_capture_state(*capture, renderer.device) return;
            capture_result = capture_all_monitors(*capture);
        }
        if capture_result <= 0 return;

        cache_monitor_background(*renderer, *capture);
        release_all_frames(*capture);
    }

    if !renderer.cached_background.srv return;

    reset(*capture_arena);
    capture_allocator := Allocator.{proc = flat_pool_allocator_proc, data = *capture_arena};
    selection_reset(*selection);
    panel_sync_active();
    annotation_init(*selection, capture_allocator);

    snap_enabled   = false;
    snap_held_mods = live_mods;
    last_snap_entry = null;

    cursor_pos: POINT;
    GetCursorPos(*cursor_pos);
    ScreenToClient(overlay_window, *cursor_pos);
    last_mouse_x = cursor_pos.x;
    last_mouse_y = cursor_pos.y;

    window_entries.data  = cast(*Window_Entry) alloc(size_of(Window_Entry) * MAX_WINDOW_ENTRIES,, capture_allocator);
    window_entries.count = 0;
    if window_entries.data {
        EnumWindows(collect_window_entries, 0);
    }

    if !render_overlay() return;

    DwmFlush();
    ShowWindow(overlay_window, SW_SHOW);
    SetForegroundWindow(overlay_window);
    BringWindowToTop(overlay_window);
    SetCapture(overlay_window);
    ClipCursor(null);

    set_mode_cursor();
    is_capturing = true;
    selection.is_selecting = true;
}

hide_overlay :: () {
    ReleaseCapture();
    ShowWindow(overlay_window, SW_HIDE);

    panel_state.is_open = false;
    save_settings();

    selection_reset(*selection);

    // NOTE(zaddish): dont destroy the swap chain here because a flip model swap chain
    // has to be the only one ever associated with its HWND, and D3D11 defers destruction of a
    // released flip swap chain
    // its buffers stay shared with the DWM so destroying and recreating it per capture left
    // the DWM compositing the prevous swap chains last frame for one frame on the next reveal
    // so we keep one swap chain for the windows lifetime and ResizeBuffers on display change
    release_session_textures(*renderer);

    SetCursor(cursor_arrow);
    is_capturing = false;
}

render_overlay :: () -> bool {
    // 1 precondition for the whole frame: device resources are up (ready), the
    // swap chain has a render target, and the capture produced a background. 
    // the rest of the pipeline after this makes sure it cant do anything dumb
    // now i dont have to keep rechecking each handle
    if !renderer.ready || !renderer.render_target || !renderer.cached_background.srv return false;

    ID3D11DeviceContext_OMSetRenderTargets(renderer.ctx, 1, *renderer.render_target, null);

    viewport: D3D11_VIEWPORT;
    viewport.Width    = cast(float) renderer.width;
    viewport.Height   = cast(float) renderer.height;
    viewport.MaxDepth = 1.0;
    ID3D11DeviceContext_RSSetViewports(renderer.ctx, 1, *viewport);

    select_rect := selection_get_rect(*selection);
    W := cast(float) renderer.width;
    H := cast(float) renderer.height;

    constants: Overlay_Const_Buffer;
    constants.selection_rect[0] = cast(float) select_rect.left                       / W;
    constants.selection_rect[1] = cast(float) select_rect.top                        / H;
    constants.selection_rect[2] = cast(float) (select_rect.right  - select_rect.left) / W;
    constants.selection_rect[3] = cast(float) (select_rect.bottom - select_rect.top)  / H;
    constants.dim_factor        = 0.4;
    constants.texel_size        = .[1.0 / W, 1.0 / H];
    update_constant_buffer(renderer.ctx, renderer.constant_buffer, *constants, size_of(Overlay_Const_Buffer));

    ID3D11DeviceContext_VSSetShader             (renderer.ctx, renderer.vertex_shader, null, 0);
    ID3D11DeviceContext_PSSetShader             (renderer.ctx, renderer.overlay_shader, null, 0);
    ID3D11DeviceContext_PSSetConstantBuffers    (renderer.ctx, 0, 1, *renderer.constant_buffer);
    ID3D11DeviceContext_PSSetSamplers           (renderer.ctx, 0, 1, *renderer.sampler);
    ID3D11DeviceContext_PSSetShaderResources    (renderer.ctx, 0, 1, *renderer.cached_background.srv);
    ID3D11DeviceContext_IASetInputLayout        (renderer.ctx, null);
    ID3D11DeviceContext_IASetPrimitiveTopology  (renderer.ctx, .TRIANGLELIST);
    ID3D11DeviceContext_Draw                    (renderer.ctx, 3, 0);

    render_annotations(*renderer, *selection, 0, 0, cast(s32) renderer.width, cast(s32) renderer.height);

    if !selection.is_dragging && selection.annotation_mode != .CENSOR {
        ui_begin_frame();
        render_brush_cursor(*renderer, selection.annotation_mode,
                            cast(float) last_mouse_x, cast(float) last_mouse_y,
                            panel_state.width, panel_state.color, *selection);
        ui_flush(*renderer);
    }

    mode_idx := cast(s32) selection.annotation_mode;
    if mode_idx >= 0 && mode_idx < MODE_LABEL_COUNT {
        font_h := font_height_for_point(last_mouse_x, last_mouse_y, 12);
        label  := label_cache_get(*renderer.label_cache, renderer.device, MODE_LABELS[mode_idx], font_h);
        if label.srv {
            render_mode_label(*renderer, label, last_mouse_x, last_mouse_y,
                              cast(s32) renderer.width, cast(s32) renderer.height);
        }
    }

    ui_mouse_x = cast(float) last_mouse_x;
    ui_mouse_y = cast(float) last_mouse_y;
    // mouse state is set per msg in WM_LBUTTONDOWN/UP before render
    ui_begin_frame();
    ui_draw_panel(*renderer, cast(s32) renderer.width, cast(s32) renderer.height);
    ui_flush(*renderer);
    ui_render_deferred_labels(*renderer);
    ui_mouse_went_down = false;

    return renderer_present(*renderer);
}

refresh_overlay :: () {
    if !render_overlay() hide_overlay();
}

Save_File_Prompt_Result :: enum u32 #specified {
    CHOSEN    :: 0;
    CANCELLED :: 1;
    FAILED    :: 2;
}

prompt_for_save_file :: (file: *u16, count: u32) -> Save_File_Prompt_Result, err_code: u32 {
    ofn: OPENFILENAMEW;
    ofn.lStructSize = size_of(OPENFILENAMEW);
    ofn.hwndOwner   = overlay_window;
    ofn.lpstrFile   = file;
    ofn.nMaxFile    = count;
    ofn.lpstrFilter = W_SAVE_FILTER.data;
    ofn.nFilterIndex = 1;
    ofn.Flags       = OFN_OVERWRITEPROMPT | OFN_NOCHANGEDIR;
    ofn.lpstrDefExt = W_EXT_PNG.data;
    if GetSaveFileNameW(*ofn) == .TRUE return .CHOSEN, 0;
    // CommDlgExtendedError returns 0 when the user cancelled and not zero
    // for real failures 
    err := CommDlgExtendedError();
    if err == 0 return .CANCELLED, 0;
    return .FAILED, err;
}

finalise_capture :: (region: RECT) {
    file_buf: [MAX_PATH] u16;
    copy_utf8_to_wide_buffer(*file_buf, "screenshot.png");
    if capture_mode == .FILE {
        prompt, err := prompt_for_save_file(file_buf.data, xx file_buf.count);
        if #complete prompt == {
            case .CHOSEN;
            case .CANCELLED; hide_overlay(); return;
            case .FAILED;
                user_message_error("save dialog failed (code %)", err);
                hide_overlay();
                return;
        }
    }

    pixels := acquire_selection_pixels(*renderer, region, *selection);
    if #complete capture_mode == {
        case .FILE;
            if !write_pixels_to_file(wic_factory, pixels, file_buf.data) {
                user_message_error("failed to save screenshot to disk");
            }
        case .CLIPBOARD;
            if !write_pixels_to_clipboard(pixels) {
                user_message_error("failed to copy screenshot to clipboard");
            }
    }
    // NOTE(zaddish): must release pixels BEFORE hide_overlay cuz hide_overlay
    // releases the cached_staging texture, and release_output_pixels needs
    // to Unmap it first
    release_output_pixels(*pixels);
    hide_overlay();
}

window_proc :: (window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT #c_call {
    push_context callback_context {
        if message == {
            case WM_HOTKEY; {
                if !is_capturing && !hotkey_dialog show_overlay();
                return 0;
            }

            case WM_TRAYICON; {
                event := LOWORD(lparam);
                if event == WM_RBUTTONUP || event == WM_CONTEXTMENU {
                    show_tray_menu();
                } else if event == WM_LBUTTONDBLCLK {
                    if !is_capturing show_overlay();
                }
                return 0;
            }

            case WM_COMMAND; {
                cmd := LOWORD(wparam);
                if cmd == IDM_QUIT          { PostQuitMessage(0); return 0; }
                if cmd == IDM_STARTUP       { set_startup_enabled(!is_startup_enabled()); return 0; }
                // one per IDM_HOTKEY_<i>
                #insert #run () -> string {
                    b: String_Builder;
                    for HOTKEY_SPECS {
                        print_to_builder(*b, "if cmd == IDM_HOTKEY_% { show_hotkey_dialog(cast(HINSTANCE) GetModuleHandleW(null), %); return 0; }\n", it_index, it_index);
                    }
                    return builder_to_string(*b);
                }();
                return 0;
            }

            case WM_LBUTTONDOWN; {
                if is_capturing {
                    x := GET_X_LPARAM(lparam);
                    y := GET_Y_LPARAM(lparam);
                    last_mouse_x = x;
                    last_mouse_y = y;

                    ui_mouse_went_down = true;
                    ui_mouse_down      = true;

                    // check if click lands inside the panel
                    if panel_state.is_open {
                        if point_in_rect(cast(float) x, cast(float) y, panel_last_rect) {
                            refresh_overlay();
                            ui_mouse_went_down = false;
                            return 0;
                        }
                        panel_state.is_open = false;
                        set_mode_cursor();
                    }

                    if !selection.is_annotating && !selection.is_censoring {
                        update_snap_enabled();
                        if snap_enabled && (live_mods & MOD_SHIFT) {
                            entry := find_window_entry_at_point(window_entries, x, y);
                            if entry {
                                finalise_capture(entry.snap_bounds);
                                return 0;
                            }
                        }

                        selection_begin(*selection, x, y);
                        SetCursor(cursor_cross);
                    }
                }
                return 0;
            }

            case WM_MOUSEMOVE; {
                if is_capturing {
                    x := GET_X_LPARAM(lparam);
                    y := GET_Y_LPARAM(lparam);
                    update_highlight_cursor_direction(cast(float)(x - last_mouse_x), cast(float)(y - last_mouse_y));
                    last_mouse_x = x;
                    last_mouse_y = y;

                    if selection.is_dragging {
                        selection_update(*selection, x, y);
                        refresh_overlay();
                    } else if selection.is_censoring || selection.is_annotating {
                        draw_x := x;
                        draw_y := y;

                        // ctrl => snap to nearest axis after a threshold
                        if selection.snap_axis == -1 {
                            dx := x - selection.snap_start_x;
                            dy := y - selection.snap_start_y;
                            if dx * dx + dy * dy > 100 {
                                abs_dx := ifx dx < 0 then -dx else dx;
                                abs_dy := ifx dy < 0 then -dy else dy;
                                is_vertical := abs_dy > abs_dx;
                                selection.snap_axis       = xx (ifx is_vertical then 2 else 1);
                                selection.snap_axis_value = ifx is_vertical then selection.snap_start_x else selection.snap_start_y;
                            }
                        }

                        if selection.snap_axis == 1       draw_y = selection.snap_axis_value;
                        else if selection.snap_axis == 2  draw_x = selection.snap_axis_value;

                        if selection.is_censoring censor_update(*selection, draw_x, draw_y);
                        else                      annotation_update(*selection, draw_x, draw_y);
                        refresh_overlay();
                    } else {
                        update_snap_enabled();
                        if snap_enabled update_snap_preview(x, y);
                        refresh_overlay();
                    }
                }
                return 0;
            }

            case WM_LBUTTONUP; {
                ui_mouse_down      = false;
                ui_mouse_went_down = false;
                last_mouse_x = GET_X_LPARAM(lparam);
                last_mouse_y = GET_Y_LPARAM(lparam);
                if panel_state.is_open refresh_overlay();
                if is_capturing && selection.is_dragging {
                    selection_end(*selection);
                    rect := selection_get_rect(*selection);
                    if (rect.right - rect.left) > 1 && (rect.bottom - rect.top) > 1 {
                        finalise_capture(rect);
                    } else {
                        hide_overlay();
                    }
                }
                return 0;
            }

            case WM_RBUTTONDOWN; {
                if is_capturing {
                    x := GET_X_LPARAM(lparam);
                    y := GET_Y_LPARAM(lparam);
                    last_mouse_x = x;
                    last_mouse_y = y;

                    if panel_state.is_open {
                        if point_in_rect(cast(float) x, cast(float) y, panel_last_rect) {
                            ui_right_clicked = true;
                            refresh_overlay();
                            ui_right_clicked = false;
                            return 0;
                        }
                        panel_state.is_open = false;
                    }
                    set_mode_cursor();
                    mode     := selection.annotation_mode;
                    ctrl_held := (GetKeyState(VK_CONTROL) & 0x8000) != 0;

                    if #complete mode == {
                        case .CENSOR;    censor_begin(*selection, x, y);
                        case .LINE;      annotation_begin(*selection, x, y, .LINE);
                        case .HIGHLIGHT; annotation_begin(*selection, x, y, .HIGHLIGHT);
                    }

                    if ctrl_held && mode != .CENSOR {
                        selection.snap_start_x = x;
                        selection.snap_start_y = y;
                        selection.snap_axis    = -1;
                    }

                    SetCursor(null);
                }
                return 0;
            }

            case WM_RBUTTONUP; {
                if is_capturing {
                    if selection.is_censoring {
                        censor_end(*selection);
                        refresh_overlay();
                    } else if selection.is_annotating {
                        annotation_end(*selection);
                        refresh_overlay();
                    }
                    set_mode_cursor();
                }
                return 0;
            }

            case WM_MBUTTONDOWN; {
                if is_capturing {
                    annotation_undo(*selection);
                    refresh_overlay();
                }
                return 0;
            }

            case WM_SETCURSOR; {
                if is_capturing return 1;
            }

            case WM_CHAR; {
                if is_capturing && panel_state.text_editing {
                    ui_handle_char(cast(u32) wparam);
                    refresh_overlay();
                }
                return 0;
            }

            case WM_KEYDOWN; {
                if is_capturing {
                    // text input mode eats esc/enter, passes others to WM_CHAR via TranslateMessage
                    if panel_state.text_editing {
                        if wparam == VK_ESCAPE { ui_cancel_text_edit(); refresh_overlay(); return 0; }
                        if wparam == VK_RETURN { ui_confirm_text_edit(); refresh_overlay(); return 0; }
                        if wparam == VK_BACK   { ui_handle_char(0x08); refresh_overlay(); return 0; }
                        return 0;
                    }

                    mid_stroke := selection.is_annotating || selection.is_censoring || selection.is_dragging;
                    if wparam == VK_ESCAPE {
                        if panel_state.is_open {
                            panel_state.is_open = false;
                            set_mode_cursor();
                            refresh_overlay();
                        } else if selection.is_dragging {
                            selection_end(*selection);
                            selection_set_rect(*selection, RECT.{});
                            set_mode_cursor();
                            refresh_overlay();
                        } else {
                            hide_overlay();
                        }
                    } else if wparam == #char "Z" && (GetKeyState(VK_CONTROL) & 0x8000) != 0 {
                        annotation_undo(*selection);
                        refresh_overlay();
                    } else if wparam == VK_TAB {
                        panel_state.is_open = !panel_state.is_open;
                        if panel_state.is_open {
                            panel_state.anchor_x = last_mouse_x;
                            panel_state.anchor_y = last_mouse_y;
                        }
                        set_mode_cursor();
                        refresh_overlay();
                    } else if !mid_stroke && live_mods == 0 && wparam >= #char "1" && wparam < #char "1" + ANNOTATION_MODE_COUNT {
                        panel_save_active();
                        selection.annotation_mode = cast(Annotation_Mode) (cast(s32) wparam - #char "1");
                        panel_sync_active();
                        set_mode_cursor();
                        refresh_overlay();
                    }
                }
                return 0;
            }

            case WM_MOUSEWHEEL; {
                if is_capturing {
                    mid_stroke := selection.is_annotating || selection.is_censoring || selection.is_dragging;
                    if !mid_stroke {
                        delta := GET_WHEEL_DELTA_WPARAM(wparam);
                        ctrl_held := (GetKeyState(VK_CONTROL) & 0x8000) != 0;
                        if ctrl_held && selection.annotation_mode != .CENSOR {
                            step := ifx delta > 0 then 2.0 else -2.0;
                            panel_state.width = clamp(panel_state.width + step, 1.0, 100.0);
                            panel_save_active();
                        } else {
                            mode := cast(s32) selection.annotation_mode;
                            mode -= (cast(s32) delta >> 31) | 1;
                            if mode < 0                          mode = ANNOTATION_MODE_COUNT - 1;
                            if mode >= ANNOTATION_MODE_COUNT     mode = 0;
                            panel_save_active();
                            selection.annotation_mode = cast(Annotation_Mode) mode;
                            panel_sync_active();
                            set_mode_cursor();
                        }
                        refresh_overlay();
                    }
                }
                return 0;
            }

            case WM_MODIFIERCHANGED; {
                if !is_capturing return 0;
                if selection.is_dragging || selection.is_annotating || selection.is_censoring return 0;
                update_snap_enabled();
                if snap_enabled update_snap_preview(last_mouse_x, last_mouse_y);
                return 0;
            }

            case WM_DISPLAYCHANGE; {
                vx := GetSystemMetrics(SM_XVIRTUALSCREEN);
                vy := GetSystemMetrics(SM_YVIRTUALSCREEN);
                vw := GetSystemMetrics(SM_CXVIRTUALSCREEN);
                vh := GetSystemMetrics(SM_CYVIRTUALSCREEN);
                SetWindowPos(window, null, vx, vy, vw, vh, SWP_NOZORDER | SWP_NOACTIVATE);
                renderer_resize(*renderer, cast(u32) vw, cast(u32) vh);
                // any cached glyph texture could now be at the wrong effective DPI
                // so im gonna bake lazily again
                label_cache_invalidate(*renderer.label_cache);
                return 0;
            }

            case WM_DPICHANGED; {
                label_cache_invalidate(*renderer.label_cache);
                return 0;
            }

            case WM_DESTROY; {
                remove_tray_icon();
                PostQuitMessage(0);
                return 0;
            }
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }
}

// utf8 -> fixed size null terminated wchar_t buffer
copy_utf8_to_wide_buffer :: (dest: *[$N] u16, src: string) {
    wide := utf8_to_wide(src,, temp);
    i := 0;
    while wide[i] != 0 && i < N - 1 {
        (<<dest)[i] = wide[i];
        i += 1;
    }
    (<<dest)[i] = 0;
}

#import "Flat_Pool";
