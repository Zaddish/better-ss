UI_MAX_VERTICES :: 16384;

UI_Rect :: struct { x, y, w, h: float; }

Tool_Settings :: struct {
    color:     Vector3 = .{1.0, 0.2, 0.2};
    width:     float   = 5.0;
    stabilize: float   = 0.10;
    hsv_hue:   float   = 0.0;
    hsv_sat:   float   = 1.0;
    hsv_val:   float   = 0.9;
}

MODE_COUNT :: ANNOTATION_MODE_COUNT;

DEFAULT_PER_MODE :: Tool_Settings.[
    .{color = .{1.0, 0.2, 0.2},  width = 5.0, stabilize = 0.10, hsv_hue = 5.0,   hsv_sat = 0.80, hsv_val = 1.0},
    .{color = .{1.0, 0.95, 0.3}, width = 5.0, stabilize = 0.0,  hsv_hue = 54.0,  hsv_sat = 0.70, hsv_val = 1.0},
    .{color = .{0.1, 0.1, 0.1},  width = 5.0, stabilize = 0.0,  hsv_hue = 0.0,   hsv_sat = 0.0,  hsv_val = 0.1},
];

MODE_NAMES :: string.["LINE", "HIGHLIGHT", "CENSOR"];

Panel_State :: struct {
    is_open:    bool;
    anchor_x:   s32;
    anchor_y:   s32;

    is_global:       bool = false;
    global_settings: Tool_Settings;
    per_mode:        [MODE_COUNT] Tool_Settings = DEFAULT_PER_MODE;

    using active: Tool_Settings;

    dragging_ring: bool;
    dragging_disc: bool;

    text_editing:    bool;
    text_editing_id: s64;
    text_buf:        [16] u8;
    text_len:        s32;
    text_value_ptr:  *float;
    text_value_min:  float;
    text_value_max:  float;
}

panel_state: Panel_State;
panel_last_rect: UI_Rect;

panel_sync_active :: () {
    ps := *panel_state;
    src := ifx ps.is_global then *ps.global_settings else *ps.per_mode[cast(s32) selection.annotation_mode];
    ps.active = src.*;
}

panel_save_active :: () {
    ps := *panel_state;
    dst := ifx ps.is_global then *ps.global_settings else *ps.per_mode[cast(s32) selection.annotation_mode];
    dst.* = ps.active;
}

// per frame input
ui_mouse_x:         float;
ui_mouse_y:         float;
ui_mouse_down:      bool;
ui_mouse_went_down: bool;
ui_right_clicked:   bool;

// vertex buffer
ui_vertices:     [UI_MAX_VERTICES] UI_Vertex;
ui_vertex_count: s32;

// which widget owns the drag
ui_active_id: s64;

ui_panel_font_height: s32;

ui_start_text_edit :: (id: s64, ptr: *float, mn: float, mx: float) {
    ps := *panel_state;
    ps.text_editing    = true;
    ps.text_editing_id = id;
    ps.text_value_ptr  = ptr;
    ps.text_value_min  = mn;
    ps.text_value_max  = mx;
    s := tprint("%", formatFloat(ptr.*, trailing_width=2, zero_removal=.NO));
    ps.text_len = cast(s32) min(cast(s64) s.count, 15);
    memcpy(ps.text_buf.data, s.data, ps.text_len);
    ps.text_buf[ps.text_len] = 0;
}

ui_cancel_text_edit :: () {
    ps := *panel_state;
    ps.text_editing    = false;
    ps.text_editing_id = 0;
    ps.text_value_ptr  = null;
}

ui_confirm_text_edit :: () {
    ps := *panel_state;
    if !ps.text_editing return;
    text: string;
    text.data  = ps.text_buf.data;
    text.count = ps.text_len;
    val, ok := string_to_float(text);
    if ok && ps.text_value_ptr {
        ps.text_value_ptr.* = clamp(cast(float) val, ps.text_value_min, ps.text_value_max);
    }
    ui_cancel_text_edit();
}

ui_handle_char :: (ch: u32) {
    ps := *panel_state;
    if !ps.text_editing return;
    if ch == 0x0D { ui_confirm_text_edit(); return; }
    if ch == 0x1B { ui_cancel_text_edit();  return; }
    if ch == 0x08 {
        if ps.text_len > 0 ps.text_len -= 1;
        ps.text_buf[ps.text_len] = 0;
        return;
    }
    if ch < 0x20 || ch > 0x7E return;
    if ps.text_len >= 15 return;
    ps.text_buf[ps.text_len] = cast(u8) ch;
    ps.text_len += 1;
    ps.text_buf[ps.text_len] = 0;
}

// layout

cut_top :: (r: UI_Rect, amount: float) -> (top: UI_Rect, remainder: UI_Rect) {
    top       := r;  top.h = amount;
    remainder := r;  remainder.y += amount; remainder.h -= amount;
    return top, remainder;
}

cut_left :: (r: UI_Rect, amount: float) -> (left: UI_Rect, remainder: UI_Rect) {
    left      := r;  left.w = amount;
    remainder := r;  remainder.x += amount; remainder.w -= amount;
    return left, remainder;
}

pad_rect :: (r: UI_Rect, p: float) -> UI_Rect {
    return .{r.x + p, r.y + p, r.w - 2*p, r.h - 2*p};
}

// interaction

UI_Status :: enum_flags u32 { OVER :: 0x1; PRESSED :: 0x2; }

point_in_rect :: (px: float, py: float, r: UI_Rect) -> bool {
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}

ui_get_status :: (r: UI_Rect) -> UI_Status {
    s: UI_Status;
    if point_in_rect(ui_mouse_x, ui_mouse_y, r) {
        s |= .OVER;
        if ui_mouse_went_down s |= .PRESSED;
    }
    return s;
}

// geometry

ui_begin_frame :: () { ui_vertex_count = 0; }

ui_emit_triangle :: (p0x: float, p0y: float, p1x: float, p1y: float, p2x: float, p2y: float,
                     c0: Vector4, c1: Vector4, c2: Vector4) {
    if ui_vertex_count + 3 > UI_MAX_VERTICES return;
    v := ui_vertices.data + ui_vertex_count;
    v[0].position = .[p0x, p0y]; v[0].color = .[c0.x, c0.y, c0.z, c0.w];
    v[1].position = .[p1x, p1y]; v[1].color = .[c1.x, c1.y, c1.z, c1.w];
    v[2].position = .[p2x, p2y]; v[2].color = .[c2.x, c2.y, c2.z, c2.w];
    ui_vertex_count += 3;
}

ui_emit_quad :: (r: UI_Rect, c: Vector4) {
    x0 := r.x;       y0 := r.y;
    x1 := r.x + r.w; y1 := r.y + r.h;
    ui_emit_triangle(x0, y0, x1, y0, x1, y1, c, c, c);
    ui_emit_triangle(x0, y0, x1, y1, x0, y1, c, c, c);
}

ui_flush :: (r: *Betterss_Renderer) {
    if ui_vertex_count > 0 {
        render_ui_geometry(r, ui_vertices.data, ui_vertex_count);
        ui_vertex_count = 0;
    }
}

// HSV

hsv_to_rgb :: (h: float, s: float, v: float) -> (r: float, g: float, b: float) {
    if s <= 0.0 return v, v, v;
    hh := h;
    if hh >= 360.0 hh = 0.0;
    hh /= 60.0;
    sector := cast(s32) hh;
    ff := hh - cast(float) sector;
    p := v * (1.0 - s);
    q := v * (1.0 - s * ff);
    t := v * (1.0 - s * (1.0 - ff));
    if sector == {
        case 0; return v, t, p;
        case 1; return q, v, p;
        case 2; return p, v, t;
        case 3; return p, q, v;
        case 4; return t, p, v;
        case;   return v, p, q;
    }
}

rgb_to_hsv :: (r: float, g: float, b: float) -> (h: float, s: float, v: float) {
    mx := max(r, max(g, b));
    mn := min(r, min(g, b));
    d  := mx - mn;
    v  := mx;
    if mx <= 0.0 return 0, 0, v;
    s  := d / mx;
    if d < 0.00001 return 0, s, v;
    h: float;
    if r >= mx      h = (g - b) / d;
    else if g >= mx h = 2.0 + (b - r) / d;
    else            h = 4.0 + (r - g) / d;
    h *= 60.0;
    if h < 0.0 h += 360.0;
    return h, s, v;
}

// widgets

PANEL_BG      :: Vector4.{0.12, 0.12, 0.14, 0.92};
BUTTON_BASE   :: Vector4.{0.22, 0.22, 0.25, 1.0};
BUTTON_HOVER  :: Vector4.{0.32, 0.32, 0.38, 1.0};
BUTTON_SELECT :: Vector4.{0.15, 0.45, 0.65, 1.0};
SLIDER_TRACK  :: Vector4.{0.18, 0.18, 0.20, 1.0};
SLIDER_NUB    :: Vector4.{0.50, 0.50, 0.55, 1.0};
SLIDER_NUB_HI :: Vector4.{0.65, 0.65, 0.70, 1.0};

ui_button :: (r: UI_Rect, selected: bool, id: s64) -> bool {
    status := ui_get_status(r);
    c := ifx selected then BUTTON_SELECT else ifx (status & .OVER) then BUTTON_HOVER else BUTTON_BASE;
    ui_emit_quad(r, c);
    return (status & .PRESSED) != 0;
}

ui_slider :: (r: UI_Rect, value: *float, mn: float, mx: float, id: s64) -> bool {
    ps := *panel_state;
    if ps.text_editing && ps.text_editing_id == id {
        ui_emit_quad(r, .{0.08, 0.08, 0.12, 1.0});
        cursor_x := r.x + 4.0 + cast(float) ps.text_len * 7.0;
        ui_emit_quad(.{cursor_x, r.y + 2, 1.5, r.h - 4}, .{1, 1, 1, 0.8});
        return false;
    }

    ui_emit_quad(r, SLIDER_TRACK);

    range := mx - mn;
    if range < 0.0001 range = 1.0;
    t := clamp((value.* - mn) / range, 0.0, 1.0);

    nub_w := max(r.h * 0.8, 8.0);
    nub_x := r.x + t * (r.w - nub_w);
    nub_r := UI_Rect.{nub_x, r.y, nub_w, r.h};

    status := ui_get_status(r);
    nub_c := ifx (status & .OVER) || ui_active_id == id then SLIDER_NUB_HI else SLIDER_NUB;
    ui_emit_quad(nub_r, nub_c);

    if (status & .OVER) && ui_right_clicked {
        ui_start_text_edit(id, value, mn, mx);
        return false;
    }

    if (status & .PRESSED) ui_active_id = id;
    if ui_active_id == id {
        if !ui_mouse_down { ui_active_id = 0; return true; }
        new_t := clamp((ui_mouse_x - r.x - nub_w * 0.5) / (r.w - nub_w), 0.0, 1.0);
        value.* = mn + new_t * range;
        return true;
    }
    return false;
}

ui_color_swatch :: (r: UI_Rect, swatch_color: Vector3, id: s64) -> bool {
    c := Vector4.{swatch_color.x, swatch_color.y, swatch_color.z, 1.0};
    status := ui_get_status(r);
    if status & .OVER {
        ui_emit_quad(.{r.x - 1, r.y - 1, r.w + 2, r.h + 2}, .{1, 1, 1, 0.5});
    }
    ui_emit_quad(r, c);
    return (status & .PRESSED) != 0;
}

// HSV wheel

HSV_RING_SEGMENTS :: 80;
HSV_SV_STRIPS     :: 30;

ui_hsv_wheel :: (area: UI_Rect, ps: *Panel_State, id_base: s64) {
    cx := area.x + area.w * 0.5;
    cy := area.y + area.h * 0.5;
    outer_r := min(area.w, area.h) * 0.5;
    inner_r := outer_r * 0.72;
    disc_r  := inner_r * 0.88;

    for i: 0 .. HSV_RING_SEGMENTS - 1 {
        t0 := cast(float) i       / cast(float) HSV_RING_SEGMENTS;
        t1 := cast(float) (i + 1) / cast(float) HSV_RING_SEGMENTS;
        a0 := t0 * TAU;
        a1 := t1 * TAU;
        cos0 := cos(a0); sin0 := sin(a0);
        cos1 := cos(a1); sin1 := sin(a1);

        r0, g0, b0 := hsv_to_rgb(t0 * 360.0, 1.0, 0.9);
        r1, g1, b1 := hsv_to_rgb(t1 * 360.0, 1.0, 0.9);
        c0 := Vector4.{r0, g0, b0, 1.0};
        c1 := Vector4.{r1, g1, b1, 1.0};

        ix0 := cx + cos0 * inner_r;  iy0 := cy + sin0 * inner_r;
        ox0 := cx + cos0 * outer_r;  oy0 := cy + sin0 * outer_r;
        ix1 := cx + cos1 * inner_r;  iy1 := cy + sin1 * inner_r;
        ox1 := cx + cos1 * outer_r;  oy1 := cy + sin1 * outer_r;

        ui_emit_triangle(ix0, iy0, ox0, oy0, ox1, oy1, c0, c0, c1);
        ui_emit_triangle(ix0, iy0, ox1, oy1, ix1, iy1, c0, c1, c1);
    }

    sq_half := disc_r * 0.7071;
    sq_x0 := cx - sq_half;
    sq_y0 := cy - sq_half;
    sq_size := sq_half * 2.0;

    make_sv_color :: (h: float, s: float, v: float) -> Vector4 {
        r, g, b := hsv_to_rgb(h, s, v);
        return .{r, g, b, 1.0};
    }

    for j: 0 .. HSV_SV_STRIPS - 1 {
        for i: 0 .. HSV_SV_STRIPS - 1 {
            s0 := cast(float) i       / cast(float) HSV_SV_STRIPS;
            s1 := cast(float) (i + 1) / cast(float) HSV_SV_STRIPS;
            v0 := 1.0 - cast(float) j       / cast(float) HSV_SV_STRIPS;
            v1 := 1.0 - cast(float) (j + 1) / cast(float) HSV_SV_STRIPS;

            h := ps.hsv_hue;
            c00 := make_sv_color(h, s0, v0);
            c10 := make_sv_color(h, s1, v0);
            c01 := make_sv_color(h, s0, v1);
            c11 := make_sv_color(h, s1, v1);

            x0 := sq_x0 + s0 * sq_size;
            x1 := sq_x0 + s1 * sq_size;
            y0 := sq_y0 + (1.0 - v0) * sq_size;
            y1 := sq_y0 + (1.0 - v1) * sq_size;

            ui_emit_triangle(x0, y0, x1, y0, x1, y1, c00, c10, c11);
            ui_emit_triangle(x0, y0, x1, y1, x0, y1, c00, c11, c01);
        }
    }

    white :: Vector4.{1, 1, 1, 1};

    ring_angle := ps.hsv_hue / 360.0 * TAU;
    mrk := (inner_r + outer_r) * 0.5;
    mx := cx + cos(ring_angle) * mrk;
    my := cy + sin(ring_angle) * mrk;
    ui_emit_quad(.{mx - 4, my - 4, 8, 8}, white);

    disc_sx := sq_x0 + ps.hsv_sat * sq_size;
    disc_sy := sq_y0 + (1.0 - ps.hsv_val) * sq_size;
    ui_emit_quad(.{disc_sx - 3, disc_sy - 3, 6, 6}, white);

    dx := ui_mouse_x - cx;
    dy := ui_mouse_y - cy;
    dist := sqrt(dx * dx + dy * dy);

    ring_id := id_base;
    disc_id := id_base + 1;

    if ui_mouse_went_down {
        if dist >= inner_r && dist <= outer_r {
            ui_active_id = ring_id;
            ps.dragging_ring = true;
        } else if ui_mouse_x >= sq_x0 && ui_mouse_x <= sq_x0 + sq_size &&
                  ui_mouse_y >= sq_y0 && ui_mouse_y <= sq_y0 + sq_size {
            ui_active_id = disc_id;
            ps.dragging_disc = true;
        }
    }

    if !ui_mouse_down {
        if ps.dragging_ring { ps.dragging_ring = false; if ui_active_id == ring_id ui_active_id = 0; }
        if ps.dragging_disc { ps.dragging_disc = false; if ui_active_id == disc_id ui_active_id = 0; }
    }

    if ps.dragging_ring {
        angle := atan2(dy, dx);
        if angle < 0 angle += TAU;
        ps.hsv_hue = angle / TAU * 360.0;
    }

    if ps.dragging_disc {
        ps.hsv_sat = clamp((ui_mouse_x - sq_x0) / sq_size, 0.0, 1.0);
        ps.hsv_val = 1.0 - clamp((ui_mouse_y - sq_y0) / sq_size, 0.0, 1.0);
    }

    if ps.dragging_ring || ps.dragging_disc {
        r, g, b := hsv_to_rgb(ps.hsv_hue, ps.hsv_sat, ps.hsv_val);
        ps.color = .{r, g, b};
    }
}

// panel

PANEL_WIDTH_BASE  :: 260.0;
ROW_HEIGHT_BASE   :: 28.0;
PADDING_BASE      :: 8.0;
SWATCH_SIZE_BASE  :: 22.0;
INDICATOR_BASE    :: 20.0;
INDICATOR_MARGIN  :: 6.0;
PANEL_ANCHOR_LIFT :: 20.0;
SWATCH_GAP_BASE   :: 4.0;

PRESET_COLORS :: Vector3.[
    .{1.0, 0.2, 0.2},
    .{1.0, 0.65, 0.0},
    .{0.2, 0.8, 0.2},
    .{0.3, 0.5, 1.0},
    .{1.0, 1.0, 1.0},
    .{0.1, 0.1, 0.1},
];

ui_draw_panel :: (r: *Betterss_Renderer, screen_w: s32, screen_h: s32) -> consumed_click: bool {
    ps := *panel_state;
    consumed := false;
    ui_panel_font_height = font_height_for_point(ps.anchor_x, ps.anchor_y, 10);

    indicator_scale := cast(float) dpi_for_point(screen_w - 32, screen_h - 32) / 96.0;
    indicator_size := INDICATOR_BASE    * indicator_scale;
    indicator_marg := INDICATOR_MARGIN  * indicator_scale;
    indicator := UI_Rect.{cast(float) screen_w - indicator_size - indicator_marg, cast(float) screen_h - indicator_size - indicator_marg, indicator_size, indicator_size};
    ui_emit_quad(indicator, .{ps.color.x, ps.color.y, ps.color.z, 0.8});

    if !ps.is_open {
        if ui_get_status(indicator) & .PRESSED {
            ps.is_open = true;
            ps.anchor_x = cast(s32) ui_mouse_x;
            ps.anchor_y = cast(s32) ui_mouse_y;
            consumed = true;
        }
        return consumed;
    }

    mode := cast(s32) selection.annotation_mode;
    is_line      := mode == 0;
    is_highlight := mode == 1;
    is_censor    := mode == 2;

    panel_scale := cast(float) dpi_for_point(ps.anchor_x, ps.anchor_y) / 96.0;
    PANEL_WIDTH := PANEL_WIDTH_BASE * panel_scale;
    ROW_HEIGHT  := ROW_HEIGHT_BASE  * panel_scale;
    PADDING     := PADDING_BASE     * panel_scale;
    SWATCH_SIZE := SWATCH_SIZE_BASE * panel_scale;
    SWATCH_GAP  := SWATCH_GAP_BASE  * panel_scale;
    ANCHOR_LIFT := PANEL_ANCHOR_LIFT * panel_scale;

    //  compute panel height dynamically based on which widgets are visible
    panel_h := PADDING * 2.0;                      // top + bottom padding
    panel_h += ROW_HEIGHT;                         // mode buttons
    panel_h += PADDING + PANEL_WIDTH - PADDING*2;  // gap + HSV wheel
    if is_line || is_highlight {
        panel_h += PADDING + ROW_HEIGHT;           // stabilise slider
    }
    if is_line {
        panel_h += PADDING * 0.5 + ROW_HEIGHT;     // width slider
    }
    panel_h += PADDING + SWATCH_SIZE;              // presets
    panel_h += PADDING + ROW_HEIGHT;               // global toggle

    px := clamp(cast(float) ps.anchor_x - PANEL_WIDTH * 0.5, 0.0, cast(float) screen_w - PANEL_WIDTH);
    py := clamp(cast(float) ps.anchor_y - ANCHOR_LIFT, 0.0, cast(float) screen_h - panel_h);
    panel := UI_Rect.{px, py, PANEL_WIDTH, panel_h};
    panel_last_rect = panel;

    ui_emit_quad(panel, PANEL_BG);

    inner := pad_rect(panel, PADDING);
    consumed = point_in_rect(ui_mouse_x, ui_mouse_y, panel) && (ui_mouse_went_down || ui_mouse_down);

    // mode buttons
    mode_row: UI_Rect;
    mode_row, inner = cut_top(inner, ROW_HEIGHT);
    btn_w := (mode_row.w - PADDING * 2) / 3.0;
    for i: 0 .. 2 {
        br := UI_Rect.{mode_row.x + cast(float) i * (btn_w + PADDING), mode_row.y, btn_w, mode_row.h};
        if ui_button(br, mode == i, 100 + cast(s64) i) {
            panel_save_active();
            selection.annotation_mode = cast(Annotation_Mode) i;
            panel_sync_active();
            consumed = true;
        }
    }

    _, inner = cut_top(inner, PADDING);

    // colour wheel
    wheel_size := inner.w;
    wheel_row: UI_Rect;
    wheel_row, inner = cut_top(inner, wheel_size);
    ui_hsv_wheel(wheel_row, ps, 200);

    // stabilize slider
    smooth_row: UI_Rect;
    if is_line || is_highlight {
        _, inner = cut_top(inner, PADDING);
        smooth_row, inner = cut_top(inner, ROW_HEIGHT);
        ui_slider(smooth_row, *ps.stabilize, 0.0, 1.0, 300);
    }

    // width slider
    width_row: UI_Rect;
    if is_line {
        _, inner = cut_top(inner, PADDING * 0.5);
        width_row, inner = cut_top(inner, ROW_HEIGHT);
        ui_slider(width_row, *ps.width, 1.0, 100.0, 301);
    }

    _, inner = cut_top(inner, PADDING);

    // colour presets
    swatch_row: UI_Rect;
    swatch_row, inner = cut_top(inner, SWATCH_SIZE);
    for i: 0 .. PRESET_COLORS.count - 1 {
        sr := UI_Rect.{swatch_row.x + cast(float) i * (SWATCH_SIZE + SWATCH_GAP), swatch_row.y, SWATCH_SIZE, SWATCH_SIZE};
        if ui_color_swatch(sr, PRESET_COLORS[i], 400 + cast(s64) i) {
            ps.active.color = PRESET_COLORS[i];
            ps.active.hsv_hue, ps.active.hsv_sat, ps.active.hsv_val = rgb_to_hsv(PRESET_COLORS[i].x, PRESET_COLORS[i].y, PRESET_COLORS[i].z);
            consumed = true;
        }
    }

    _, inner = cut_top(inner, PADDING);

    // global toggle
    global_row: UI_Rect;
    global_row, inner = cut_top(inner, ROW_HEIGHT);
    if ui_button(global_row, ps.is_global, 50) {
        panel_save_active();
        ps.is_global = !ps.is_global;
        panel_sync_active();
        consumed = true;
    }

    // text labels
    ui_deferred_label_count = 0;

    for i: 0 .. 2 {
        ui_defer_label(r, mode_row.x + cast(float) i * (btn_w + PADDING), mode_row.y, btn_w, mode_row.h, MODE_NAMES[i]);
    }

    if is_line || is_highlight {
        text: string;
        if ps.text_editing && ps.text_editing_id == 300 {
            s: string; s.data = ps.text_buf.data; s.count = ps.text_len;
            text = tprint("> %", s);
        } else {
            text = tprint("Stabilize %", formatFloat(ps.stabilize, trailing_width=2, zero_removal=.NO));
        }
        ui_defer_label(r, smooth_row.x, smooth_row.y, smooth_row.w, smooth_row.h, text);
    }

    if is_line {
        text: string;
        if ps.text_editing && ps.text_editing_id == 301 {
            s: string; s.data = ps.text_buf.data; s.count = ps.text_len;
            text = tprint("> %", s);
        } else {
            text = tprint("Width %", formatFloat(ps.width, trailing_width=1, zero_removal=.NO));
        }
        ui_defer_label(r, width_row.x, width_row.y, width_row.w, width_row.h, text);
    }

    global_text := ifx ps.is_global then "Global" else "Per tool";
    ui_defer_label(r, global_row.x, global_row.y, global_row.w, global_row.h, global_text);

    panel_save_active();

    return consumed;
}

// deferred text labels
// i keep a pointer to the cache owned Mode_Label so
// the texture survives across frames

UI_Deferred_Label :: struct {
    x, y, w, h: s32;
    label: *Mode_Label;
}

MAX_DEFERRED_LABELS :: 16;
ui_deferred_labels: [MAX_DEFERRED_LABELS] UI_Deferred_Label;
ui_deferred_label_count: s32;

ui_defer_label :: (r: *Betterss_Renderer, px: float, py: float, pw: float, ph: float, text: string) {
    if ui_deferred_label_count >= MAX_DEFERRED_LABELS return;
    if !r.device return;

    label := label_cache_get(*r.label_cache, r.device, text, ui_panel_font_height);
    if !label.srv return;

    idx := ui_deferred_label_count;
    ui_deferred_labels[idx].x = cast(s32) (px + (pw - cast(float) label.width) * 0.5);
    ui_deferred_labels[idx].y = cast(s32) (py + (ph - cast(float) label.height) * 0.5);
    ui_deferred_labels[idx].w = label.width;
    ui_deferred_labels[idx].h = label.height;
    ui_deferred_labels[idx].label = label;
    ui_deferred_label_count += 1;
}

ui_render_deferred_labels :: (r: *Betterss_Renderer) {
    if ui_deferred_label_count == 0 return;
    if !r.vertex_shader || !r.overlay_shader || !r.alpha_blend return;

    for i: 0 .. ui_deferred_label_count - 1 {
        dl := *ui_deferred_labels[i];
        if !dl.label || !dl.label.srv continue;

        viewport: D3D11_VIEWPORT;
        viewport.TopLeftX = cast(float) dl.x;
        viewport.TopLeftY = cast(float) dl.y;
        viewport.Width    = cast(float) dl.w;
        viewport.Height   = cast(float) dl.h;
        viewport.MaxDepth = 1.0;
        ID3D11DeviceContext_RSSetViewports(r.ctx, 1, *viewport);

        constants: Overlay_Const_Buffer;
        constants.dim_factor = 1.0;
        constants.texel_size = .[1.0 / cast(float) dl.w, 1.0 / cast(float) dl.h];
        update_constant_buffer(r.ctx, r.constant_buffer, *constants, size_of(Overlay_Const_Buffer));

        ID3D11DeviceContext_IASetInputLayout     (r.ctx, null);
        ID3D11DeviceContext_IASetPrimitiveTopology(r.ctx, .TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader          (r.ctx, r.vertex_shader, null, 0);
        ID3D11DeviceContext_PSSetShader          (r.ctx, r.overlay_shader, null, 0);
        ID3D11DeviceContext_PSSetConstantBuffers (r.ctx, 0, 1, *r.constant_buffer);
        ID3D11DeviceContext_PSSetSamplers        (r.ctx, 0, 1, *r.sampler);
        ID3D11DeviceContext_PSSetShaderResources (r.ctx, 0, 1, *dl.label.srv);

        blend_factor: [4] float;
        ID3D11DeviceContext_OMSetBlendState(r.ctx, r.alpha_blend, *blend_factor, 0xFFFFFFFF);
        ID3D11DeviceContext_Draw(r.ctx, 3, 0);
        ID3D11DeviceContext_OMSetBlendState(r.ctx, null, *blend_factor, 0xFFFFFFFF);

        null_srv: *ID3D11ShaderResourceView;
        ID3D11DeviceContext_PSSetShaderResources(r.ctx, 0, 1, *null_srv);
    }
    ui_deferred_label_count = 0;
}
