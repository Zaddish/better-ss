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


static void SelectionSetRect(selection_state *Selection, RECT R) {
    Selection->StartX = R.left;
    Selection->StartY = R.top;
    Selection->CurrentX = R.right;
    Selection->CurrentY = R.bottom;
    Selection->IsDragging = 0;
}

static void AnnotationInit(selection_state *Selection, memory_arena *Arena) {
    Selection->Annotations = (annotation_entry *)ArenaAlloc(Arena, 
        MAX_ANNOTATIONS * sizeof(annotation_entry));
    Selection->MaxAnnotations = Selection->Annotations ? MAX_ANNOTATIONS : 0;
}

// 0 is valid (first annotation)
// invalid state is determined by bounds checking
static void AnnotationBegin(selection_state *Selection, memory_arena *Arena, int X, int Y) {
    if(!Selection->Annotations) return;
    if(Selection->AnnotationCount >= Selection->MaxAnnotations) return;
    
    annotation_entry *Entry = &Selection->Annotations[Selection->AnnotationCount];
    
    Entry->Points = (line_point *)ArenaAlloc(Arena, 
        MAX_POINTS_PER_LINE * sizeof(line_point));
    
    if(Entry->Points) {
        Entry->Type = ANNOTATION_LINE;
        Entry->PointCapacity = MAX_POINTS_PER_LINE;
        Entry->PointCount = 1;
        Entry->Points[0].X = X;
        Entry->Points[0].Y = Y;
        
        Selection->CurrentAnnotationIndex = Selection->AnnotationCount;
        Selection->AnnotationCount++;
        Selection->IsAnnotating = 1;
    }
}

static void AnnotationUpdate(selection_state *Selection, int X, int Y) {
    if(!Selection->IsAnnotating) return;
    if(Selection->CurrentAnnotationIndex >= Selection->AnnotationCount) return;
    
    annotation_entry *Entry = &Selection->Annotations[Selection->CurrentAnnotationIndex];
    if(!Entry->Points) return;
    
    if(Entry->PointCount > 0) {
        line_point *LastPoint = &Entry->Points[Entry->PointCount - 1];
        int DX = X - LastPoint->X;
        int DY = Y - LastPoint->Y;
        int DistSq = DX * DX + DY * DY;
        
        if(DistSq < 4) return;
    }
    
    //TODO(zaddish): let the user know we hit capacity, or remove the LRU line
    if(Entry->PointCount >= Entry->PointCapacity) return;
    
    Entry->Points[Entry->PointCount].X = X;
    Entry->Points[Entry->PointCount].Y = Y;
    Entry->PointCount++;
}

static void AnnotationEnd(selection_state *Selection) {
    Selection->IsAnnotating = 0;
    Selection->CurrentAnnotationIndex = 0;
}

static void AnnotationUndo(selection_state *Selection) {
    if(Selection->AnnotationCount > 0) {
        Selection->AnnotationCount--;
        if(Selection->CurrentAnnotationIndex >= Selection->AnnotationCount) {
            Selection->CurrentAnnotationIndex = 0;
        }
        // note(zaddish): memory is not freed yet, it stays in the arena, and will be reset when capture ends
    }
}

static void CensorBegin(selection_state *Selection, int X, int Y) {
    if(!Selection->Annotations) return;
    if(Selection->AnnotationCount >= Selection->MaxAnnotations) return;
    
    Selection->IsCensoring = 1;
    Selection->CensorStartX = X;
    Selection->CensorStartY = Y;
    
    annotation_entry *Entry = &Selection->Annotations[Selection->AnnotationCount];
    Entry->Type = ANNOTATION_RECT;
    Entry->X0 = X;
    Entry->Y0 = Y;
    Entry->X1 = X;
    Entry->Y1 = Y;
    
    Selection->CurrentAnnotationIndex = Selection->AnnotationCount;
    Selection->AnnotationCount++;
}

static void CensorUpdate(selection_state *Selection, int X, int Y) {
    if(!Selection->IsCensoring) return;
    if(Selection->CurrentAnnotationIndex >= Selection->AnnotationCount) return;
    
    annotation_entry *Entry = &Selection->Annotations[Selection->CurrentAnnotationIndex];
    Entry->X1 = X;
    Entry->Y1 = Y;
}

static void CensorEnd(selection_state *Selection) {
    Selection->IsCensoring = 0;
    Selection->CurrentAnnotationIndex = 0;
}
