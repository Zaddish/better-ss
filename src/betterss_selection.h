/* BetterSS - Selection State Types */

#pragma once

#define MAX_ANNOTATION_LINES 128
#define MAX_POINTS_PER_LINE 2048

struct line_point
{
    int X, Y;
};

struct annotation_line
{
    line_point *Points;
    int PointCount;
    int PointCapacity;
};

struct selection_state
{
    int StartX;
    int StartY;
    int CurrentX;
    int CurrentY;
    int IsSelecting;
    int IsDragging;
    
    // Annotations
    annotation_line *Lines;
    int LineCount;
    int MaxLines;
    int IsAnnotating;
    int CurrentLineIndex;
};

static void SelectionReset(selection_state *Selection);
static void SelectionBegin(selection_state *Selection, int X, int Y);
static void SelectionUpdate(selection_state *Selection, int X, int Y);
static void SelectionEnd(selection_state *Selection);
static void SelectionCancel(selection_state *Selection);
static RECT SelectionGetRect(selection_state *Selection);

static void AnnotationInit(selection_state *Selection, memory_arena *Arena);
static void AnnotationBegin(selection_state *Selection, memory_arena *Arena, int X, int Y);
static void AnnotationUpdate(selection_state *Selection, int X, int Y);
static void AnnotationEnd(selection_state *Selection);
static void AnnotationUndo(selection_state *Selection);
static void AnnotationClear(selection_state *Selection);
