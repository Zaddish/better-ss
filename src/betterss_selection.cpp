static void SelectionReset(selection_state *Selection) {
    Selection->StartX = 0;
    Selection->StartY = 0;
    Selection->CurrentX = 0;
    Selection->CurrentY = 0;
    Selection->IsSelecting = 0;
    Selection->IsDragging = 0;
    Selection->IsAnnotating = 0;
    Selection->CurrentLineIndex = -1;
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

static void AnnotationBegin(selection_state *Selection, int X, int Y) {
    if(!Selection->Lines) {
        Selection->LineCapacity = 32;
        Selection->Lines = (annotation_line *)VirtualAlloc(0, 
            Selection->LineCapacity * sizeof(annotation_line),
            MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if(!Selection->Lines) return;
    }
    
    if(Selection->LineCount >= Selection->LineCapacity) {
        int NewCapacity = Selection->LineCapacity * 2;
        annotation_line *NewLines = (annotation_line *)VirtualAlloc(0,
            NewCapacity * sizeof(annotation_line),
            MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if(!NewLines) return;
        
        for(int i = 0; i < Selection->LineCount; i++) {
            NewLines[i] = Selection->Lines[i];
        }
        
        VirtualFree(Selection->Lines, 0, MEM_RELEASE);
        Selection->Lines = NewLines;
        Selection->LineCapacity = NewCapacity;
    }
    
    annotation_line *Line = &Selection->Lines[Selection->LineCount];
    Line->PointCapacity = 256;
    Line->Points = (line_point *)VirtualAlloc(0,
        Line->PointCapacity * sizeof(line_point),
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    
    if(Line->Points) {
        Line->PointCount = 1;
        Line->Points[0].X = X;
        Line->Points[0].Y = Y;
        
        Selection->CurrentLineIndex = Selection->LineCount;
        Selection->LineCount++;
        Selection->IsAnnotating = 1;
    }
}

static void AnnotationUpdate(selection_state *Selection, int X, int Y) {
    if(!Selection->IsAnnotating || Selection->CurrentLineIndex < 0) return;
    
    annotation_line *Line = &Selection->Lines[Selection->CurrentLineIndex];
    if(!Line->Points) return;
    
    if(Line->PointCount > 0) {
        line_point *LastPoint = &Line->Points[Line->PointCount - 1];
        int DX = X - LastPoint->X;
        int DY = Y - LastPoint->Y;
        int DistSq = DX * DX + DY * DY;
        
        if(DistSq < 4) return;
    }
    
    if(Line->PointCount >= Line->PointCapacity) {
        int NewCapacity = Line->PointCapacity * 2;
        line_point *NewPoints = (line_point *)VirtualAlloc(0,
            NewCapacity * sizeof(line_point),
            MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if(!NewPoints) return;
        
        for(int i = 0; i < Line->PointCount; i++) {
            NewPoints[i] = Line->Points[i];
        }
        
        VirtualFree(Line->Points, 0, MEM_RELEASE);
        Line->Points = NewPoints;
        Line->PointCapacity = NewCapacity;
    }
    
    Line->Points[Line->PointCount].X = X;
    Line->Points[Line->PointCount].Y = Y;
    Line->PointCount++;
}

static void AnnotationEnd(selection_state *Selection) {
    Selection->IsAnnotating = 0;
    Selection->CurrentLineIndex = -1;
}

static void AnnotationUndo(selection_state *Selection) {
    if(Selection->LineCount > 0) {
        Selection->LineCount--;
        annotation_line *Line = &Selection->Lines[Selection->LineCount];
        if(Line->Points) {
            VirtualFree(Line->Points, 0, MEM_RELEASE);
            Line->Points = 0;
            Line->PointCount = 0;
            Line->PointCapacity = 0;
        }
    }
}

static void AnnotationClear(selection_state *Selection) {
    for(int i = 0; i < Selection->LineCount; i++) {
        annotation_line *Line = &Selection->Lines[i];
        if(Line->Points) {
            VirtualFree(Line->Points, 0, MEM_RELEASE);
        }
    }
    
    if(Selection->Lines) {
        VirtualFree(Selection->Lines, 0, MEM_RELEASE);
    }
    
    Selection->Lines = 0;
    Selection->LineCount = 0;
    Selection->LineCapacity = 0;
    Selection->IsAnnotating = 0;
    Selection->CurrentLineIndex = -1;
}
