#pragma once

static int CopySelectionToClipboard(betterss_renderer *R, capture_state *C, RECT Selection, selection_state *S);
static int SaveSelectionToFile(betterss_renderer *R, capture_state *C, RECT Selection, const wchar_t *Filename, selection_state *S);