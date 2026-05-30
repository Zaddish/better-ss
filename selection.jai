MAX_ANNOTATIONS  :: 128;
// one shared point budget for every stroke this capture
// a single stroke can use as many as it wants; the only bound is the sum
// 256k points is like 1Mpx of travel at the 4px min spacing
// if u need more than this wtf are you doing bruz
MAX_TOTAL_POINTS :: 1 << 18;

Annotation_Type :: enum u32 #specified { LINE :: 0; RECT :: 1; HIGHLIGHT :: 2; }
Annotation_Mode :: enum u32 #specified { LINE :: 0; HIGHLIGHT :: 1; CENSOR :: 2; }

ANNOTATION_MODE_COUNT :: #run enum_values_as_s64(Annotation_Mode).count;

Line_Point :: struct { x, y: s32; }

Annotation_Entry :: struct {
    type:       Annotation_Type;
    points:     [] Line_Point;
    point_count: s32;
    x0, y0, x1, y1: s32;
    color:      Vector3;
    line_width: float;
    smoothing:  float;
}

Selection_State :: struct {
    start_x,   start_y:   s32;
    current_x, current_y: s32;
    is_selecting: bool;
    is_dragging:  bool;

    annotations:      *Annotation_Entry;
    annotation_count: s32;
    point_storage:    *Line_Point;
    point_capacity:   s32;
    point_cursor:     s32;   // next free point in the pool
    is_annotating:    bool;

    is_censoring:   bool;
    censor_start_x: s32;
    censor_start_y: s32;

    annotation_mode: Annotation_Mode;

    snap_axis:       s32; // 0=none, 1=locked Y, 2=locked X, -1=pending
    snap_axis_value: s32;
    snap_start_x:    s32;
    snap_start_y:    s32;

    // stabilisation!
    stab_x: float;
    stab_y: float;
}

selection_reset :: (s: *Selection_State) {
    <<s = .{};
}

selection_begin :: (s: *Selection_State, x: s32, y: s32) {
    s.start_x   = x;
    s.start_y   = y;
    s.current_x = x;
    s.current_y = y;
    s.is_dragging = true;
}

selection_update :: (s: *Selection_State, x: s32, y: s32) {
    s.current_x = x;
    s.current_y = y;
}

selection_end :: (s: *Selection_State) {
    s.is_dragging = false;
}

selection_get_rect :: (s: *Selection_State) -> RECT {
    result: RECT;
    dx := s.start_x - s.current_x;
    dy := s.start_y - s.current_y;
    mx := dx & (dx >> 31);
    my := dy & (dy >> 31);
    result.left   = s.current_x + mx;
    result.right  = s.start_x   - mx;
    result.top    = s.current_y + my;
    result.bottom = s.start_y   - my;
    return result;
}

selection_set_rect :: (s: *Selection_State, r: RECT) {
    s.start_x   = r.left;
    s.start_y   = r.top;
    s.current_x = r.right;
    s.current_y = r.bottom;
    s.is_dragging = false;
}

annotation_init :: (s: *Selection_State, allocator: Allocator) {
    s.annotations    = cast(*Annotation_Entry) alloc(size_of(Annotation_Entry) * MAX_ANNOTATIONS,, allocator);
    s.point_storage  = cast(*Line_Point)       alloc(size_of(Line_Point) * MAX_TOTAL_POINTS,, allocator);
    s.point_capacity = MAX_TOTAL_POINTS;
    s.point_cursor   = 0;
    if !s.annotations || !s.point_storage {
        s.annotations    = null;
        s.point_storage  = null;
        s.point_capacity = 0;
    }
}

annotation_begin :: (s: *Selection_State, x: s32, y: s32, type: Annotation_Type) {
    if !s.annotations || !s.point_storage return;
    if s.annotation_count >= MAX_ANNOTATIONS return;
    if s.point_cursor >= s.point_capacity return;

    entry := *s.annotations[s.annotation_count];
    entry.type        = type;
    // this stroke starts at the cursor and streams forward; it is always the last
    // allocation in the pool while it is being drawn, so appends just bump the cursor
    entry.points.data  = s.point_storage + s.point_cursor;
    entry.points.count = 1;
    entry.point_count  = 1;
    entry.points.data[0] = .{x, y};
    s.point_cursor += 1;
    entry.x0 = 0; entry.y0 = 0; entry.x1 = 0; entry.y1 = 0;
    entry.color      = panel_state.color;
    entry.line_width = panel_state.width;
    entry.smoothing  = panel_state.stabilize;

    s.stab_x = cast(float) x;
    s.stab_y = cast(float) y;

    s.annotation_count += 1;
    s.is_annotating = true;
}

annotation_update :: (s: *Selection_State, x: s32, y: s32) {
    if !s.is_annotating return;
    if s.annotation_count == 0 return;

    entry := *s.annotations[s.annotation_count - 1];

    // brush stabiliation: lagging cursor chases the mouse
    // smoothing 0 = no lag, smoothing 1 = heavy lag
    smoothing := entry.smoothing;
    mx := cast(float) x;
    my := cast(float) y;

    if smoothing < 0.01 {
        s.stab_x = mx;
        s.stab_y = my;
    } else {
        // the stabilised point only moves when the mouse exceeds a "dead zone" radius around it,
        // then it follows at a distance
        pull_radius := smoothing * 60.0 + 4.0;
        dx := mx - s.stab_x;
        dy := my - s.stab_y;
        dist := sqrt(dx * dx + dy * dy);
        if dist > pull_radius {
            // move toward mouse, maintaining pull_radius gap
            ratio := (dist - pull_radius) / dist;
            s.stab_x += dx * ratio;
            s.stab_y += dy * ratio;
        }
    }

    sx := cast(s32) (s.stab_x + 0.5);
    sy := cast(s32) (s.stab_y + 0.5);

    if entry.point_count > 0 {
        last := entry.points.data[entry.point_count - 1];
        pdx := sx - last.x;
        pdy := sy - last.y;
        min_dist : s32 = 4;
        if pdx * pdx + pdy * pdy < min_dist return;
    }

    if s.point_cursor >= s.point_capacity return;
    entry.points.data[entry.point_count] = .{sx, sy};
    entry.point_count  += 1;
    entry.points.count  = entry.point_count;
    s.point_cursor     += 1;
}

annotation_end :: (s: *Selection_State) {
    s.is_annotating = false;
    s.snap_axis       = 0;
    s.snap_axis_value = 0;
}

annotation_undo :: (s: *Selection_State) {
    if s.annotation_count > 0 {
        s.annotation_count -= 1;
        // rewind the pool cursor over the points this stroke streamed in, so the
        // space is immediately reusable    
        //
        // NOTE(zaddish): rects stream no points, so this is 0
        s.point_cursor -= s.annotations[s.annotation_count].point_count;
    }
}

censor_begin :: (s: *Selection_State, x: s32, y: s32) {
    if !s.annotations return;
    if s.annotation_count >= MAX_ANNOTATIONS return;

    s.is_censoring   = true;
    s.censor_start_x = x;
    s.censor_start_y = y;

    entry := *s.annotations[s.annotation_count];
    entry.type        = .RECT;
    entry.points.data  = null;
    entry.points.count = 0;
    entry.point_count  = 0;
    entry.x0 = x; entry.y0 = y;
    entry.x1 = x; entry.y1 = y;
    entry.color      = panel_state.color;
    entry.line_width = panel_state.width;
    entry.smoothing  = 0;

    s.annotation_count += 1;
}

censor_update :: (s: *Selection_State, x: s32, y: s32) {
    if !s.is_censoring return;
    if s.annotation_count == 0 return;
    entry := *s.annotations[s.annotation_count - 1];
    entry.x1 = x;
    entry.y1 = y;
}

censor_end :: (s: *Selection_State) {
    s.is_censoring    = false;
    s.snap_axis       = 0;
    s.snap_axis_value = 0;
}
