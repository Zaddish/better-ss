User_Message_Level :: enum u32 #specified {
    INFO    :: 0;
    WARN    :: 1;
    ERROR   :: 2;
    SUCCESS :: 3;
}

USER_MESSAGE_MAX_TEXT  :: 192;
USER_MESSAGE_MAX_TITLE :: 48;
USER_MESSAGE_CAPACITY  :: 8;

User_Message :: struct {
    text:     [USER_MESSAGE_MAX_TEXT] u8;
    text_len: s32;
    level:    User_Message_Level;
    shown:    bool;
}

user_messages:      [USER_MESSAGE_CAPACITY] User_Message;
user_message_count: s32;

W_USER_MESSAGE_TITLE_INFO    :: #run bake_wide("BetterSS");
W_USER_MESSAGE_TITLE_WARN    :: #run bake_wide("BetterSS");
W_USER_MESSAGE_TITLE_ERROR   :: #run bake_wide("BetterSS");
W_USER_MESSAGE_TITLE_SUCCESS :: #run bake_wide("BetterSS");

user_message_post :: (level: User_Message_Level, fmt: string, args: ..Any) {
    formatted := tprint(fmt, ..args);

    slot: *User_Message;
    if user_message_count < USER_MESSAGE_CAPACITY {
        slot = *user_messages[user_message_count];
        user_message_count += 1;
    } else {
        for i: 0 .. USER_MESSAGE_CAPACITY - 2 {
            user_messages[i] = user_messages[i + 1];
        }
        slot = *user_messages[USER_MESSAGE_CAPACITY - 1];
    }

    n := formatted.count;
    if n > USER_MESSAGE_MAX_TEXT n = USER_MESSAGE_MAX_TEXT;
    memcpy(slot.text.data, formatted.data, n);
    slot.text_len = cast(s32) n;
    slot.level    = level;
    slot.shown    = false;

    user_message_flush_to_tray(slot);
}

user_message_error   :: inline (fmt: string, args: ..Any) { user_message_post(.ERROR,   fmt, ..args); }
user_message_warning :: inline (fmt: string, args: ..Any) { user_message_post(.WARN,    fmt, ..args); }
user_message_success :: inline (fmt: string, args: ..Any) { user_message_post(.SUCCESS, fmt, ..args); }
user_message_info    :: inline (fmt: string, args: ..Any) { user_message_post(.INFO,    fmt, ..args); }

// flush any messages posted before the tray icon existed
// create_tray_icon calls it so startup warnings still surface once we have a hWnd
user_message_flush_pending :: () {
    for i: 0 .. user_message_count - 1 {
        slot := *user_messages[i];
        if !slot.shown user_message_flush_to_tray(slot);
    }
}

#scope_file

user_message_flush_to_tray :: (msg: *User_Message) {
    if !tray_icon.hWnd return;

    body: string;
    body.data  = msg.text.data;
    body.count = msg.text_len;

    title_w: [] u16;
    flags:   u32;
    if #complete msg.level == {
        case .INFO;    title_w = W_USER_MESSAGE_TITLE_INFO;    flags = NIIF_INFO;
        case .WARN;    title_w = W_USER_MESSAGE_TITLE_WARN;    flags = NIIF_WARNING;
        case .ERROR;   title_w = W_USER_MESSAGE_TITLE_ERROR;   flags = NIIF_ERROR;
        case .SUCCESS; title_w = W_USER_MESSAGE_TITLE_SUCCESS; flags = NIIF_INFO;
    }

    copy_wide_to_fixed(*tray_icon.szInfoTitle, title_w);
    copy_utf8_to_wide_buffer(*tray_icon.szInfo, body);

    saved_flags := tray_icon.uFlags;
    saved_info  := tray_icon.dwInfoFlags;

    tray_icon.uFlags      = saved_flags | NIF_INFO;
    tray_icon.dwInfoFlags = flags;

    Shell_NotifyIconW(NIM_MODIFY, *tray_icon);
    msg.shown = true;

    tray_icon.uFlags      = saved_flags;
    tray_icon.dwInfoFlags = saved_info;
}

copy_wide_to_fixed :: (dest: *[$N] u16, src: [] u16) {
    i := 0;
    // src includes a trailing 0 per bake_wide
    // stop at either end
    while i < src.count && src[i] != 0 && i < N - 1 {
        (<<dest)[i] = src[i];
        i += 1;
    }
    (<<dest)[i] = 0;
}
