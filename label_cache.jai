LABEL_CACHE_CAPACITY :: 64;
LABEL_CACHE_KEY_MAX  :: 64;

Label_Cache_Entry :: struct {
    key_buf:     [LABEL_CACHE_KEY_MAX] u8;
    key_len:     s16;
    font_height: s16;
    last_used:   u32;
    label:       Mode_Label;
}

Label_Cache :: struct {
    entries: [LABEL_CACHE_CAPACITY] Label_Cache_Entry;
    count:   s32;
    tick:    u32;
}

// returns a pointer to the cached Mode_Label, or null on failure
// the returned pointer is owned by the cache so do not release it
// Mode_Label is returned (and not cached) if the GDI bake fails so the
// caller can early out without a null check on the pointer itself
// not sure on how to make this more elegant tbh
label_cache_get :: (cache: *Label_Cache, device: *ID3D11Device, text: string, font_height: s32) -> *Mode_Label {
    if !device             return *ZERO_LABEL;
    if text.count == 0     return *ZERO_LABEL;
    if font_height <= 0    return *ZERO_LABEL;

    cache.tick += 1;

    // bake every time rather than pretend a truncated
    // key still identifies it. prolly bite me in the ass if i make long labels
    if text.count > LABEL_CACHE_KEY_MAX return *ZERO_LABEL;

    fh16: s16 = cast(s16) font_height;

    for i: 0 .. cache.count - 1 {
        e := *cache.entries[i];
        if e.font_height != fh16            continue;
        if cast(s32) e.key_len != text.count continue;
        if memcmp(e.key_buf.data, text.data, text.count) != 0 continue;
        e.last_used = cache.tick;
        return *e.label;
    }

    target: *Label_Cache_Entry;
    if cache.count < LABEL_CACHE_CAPACITY {
        target = *cache.entries[cache.count];
        cache.count += 1;
    } else {
        oldest_idx := 0;
        oldest_age := cache.entries[0].last_used;
        for i: 1 .. cache.count - 1 {
            if cache.entries[i].last_used < oldest_age {
                oldest_age = cache.entries[i].last_used;
                oldest_idx = i;
            }
        }
        target = *cache.entries[oldest_idx];
        release_mode_label(*target.label);
    }

    memcpy(target.key_buf.data, text.data, text.count);
    target.key_len     = cast(s16) text.count;
    target.font_height = fh16;
    target.last_used   = cache.tick;

    wide := temp_wide(text);
    target.label = bake_mode_label(device, wide, font_height);

    return *target.label;
}

label_cache_invalidate :: (cache: *Label_Cache) {
    for i: 0 .. cache.count - 1 {
        release_mode_label(*cache.entries[i].label);
    }
    cache.count = 0;
}

label_cache_release :: (cache: *Label_Cache) {
    label_cache_invalidate(cache);
    cache.tick = 0;
}

#scope_file

// stub returned when the cache cannot or should not allocate
ZERO_LABEL: Mode_Label;
