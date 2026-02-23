static void SelectionReset(selection_state *Selection) {
    *Selection = {};
}

static void SelectionBegin(selection_state *Selection, int X, int Y) {
    Selection->StartX = X;
    Selection->StartY = Y;
    Selection->CurrentX = X;
    Selection->CurrentY = Y;
    Selection->IsDragging = 1;
}

static void SelectionUpdate(selection_state *Selection, int X, int Y) {
    Selection->CurrentX = X;
    Selection->CurrentY = Y;
}

static void SelectionEnd(selection_state *Selection) {
    Selection->IsDragging = 0;
}

static void SelectionCancel(selection_state *Selection) {
    SelectionReset(Selection);
}

static RECT SelectionGetRect(selection_state *Selection) {
    RECT Result;

    if(Selection->StartX < Selection->CurrentX) {
        Result.left = Selection->StartX;
        Result.right = Selection->CurrentX;
    }
    else {
        Result.left = Selection->CurrentX;
        Result.right = Selection->StartX;
    }

    if(Selection->StartY < Selection->CurrentY) {
        Result.top = Selection->StartY;
        Result.bottom = Selection->CurrentY;
    }
    else {
        Result.top = Selection->CurrentY;
        Result.bottom = Selection->StartY;
    }

    return(Result);
}

static void AnnotationInit(selection_state *Selection, memory_arena *Arena) {
    Selection->Lines = (annotation_line *)ArenaAlloc(Arena, 
        MAX_ANNOTATION_LINES * sizeof(annotation_line));
    Selection->MaxLines = Selection->Lines ? MAX_ANNOTATION_LINES : 0;
}

// 0 is valid (first line)
// invalid state is determined by bounds checking
static void AnnotationBegin(selection_state *Selection, memory_arena *Arena, int X, int Y) {
    if(!Selection->Lines) return;
    if(Selection->LineCount >= Selection->MaxLines) return;
    
    annotation_line *Line = &Selection->Lines[Selection->LineCount];
    
    Line->Points = (line_point *)ArenaAlloc(Arena, 
        MAX_POINTS_PER_LINE * sizeof(line_point));
    
    if(Line->Points) {
        Line->PointCapacity = MAX_POINTS_PER_LINE;
        Line->PointCount = 1;
        Line->Points[0].X = X;
        Line->Points[0].Y = Y;
        
        Selection->CurrentLineIndex = Selection->LineCount;  // 0-based: first line = 0
        Selection->LineCount++;
        Selection->IsAnnotating = 1;
    }
}

static void AnnotationUpdate(selection_state *Selection, int X, int Y) {
    if(!Selection->IsAnnotating) return;
    if(Selection->CurrentLineIndex >= Selection->LineCount) return;
    
    annotation_line *Line = &Selection->Lines[Selection->CurrentLineIndex];
    if(!Line->Points) return;
    
    if(Line->PointCount > 0) {
        line_point *LastPoint = &Line->Points[Line->PointCount - 1];
        int DX = X - LastPoint->X;
        int DY = Y - LastPoint->Y;
        int DistSq = DX * DX + DY * DY;
        
        if(DistSq < 4) return;
    }
    
    //TODO(zaddish): let the user know we hit capacity, or remove the LRU line
    if(Line->PointCount >= Line->PointCapacity) return;
    
    Line->Points[Line->PointCount].X = X;
    Line->Points[Line->PointCount].Y = Y;
    Line->PointCount++;
}

static void AnnotationEnd(selection_state *Selection) {
    Selection->IsAnnotating = 0;
    Selection->CurrentLineIndex = 0;
}

static void AnnotationUndo(selection_state *Selection) {
    if(Selection->LineCount > 0) {
        Selection->LineCount--;
        if(Selection->CurrentLineIndex >= Selection->LineCount) {
            Selection->CurrentLineIndex = 0;
        }
        // note(zaddish): memory is not freed yet, it stays in the arena, and will be reset when capture ends
    }
}

static void AnnotationClear(selection_state *Selection) {
    Selection->LineCount = 0;
    Selection->IsAnnotating = 0;
    Selection->CurrentLineIndex = 0;
}
