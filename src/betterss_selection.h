/* BetterSS - Selection State Types */

#pragma once

#define MAX_ANNOTATIONS 128
#define MAX_POINTS_PER_LINE 2048

struct line_point
{
    int X, Y;
};

enum annotation_type 
{ 
    ANNOTATION_LINE = 0,
    ANNOTATION_RECT = 1 
};

struct annotation_entry
{
    annotation_type Type;
    line_point *Points;
    int PointCount;
    int PointCapacity;
    int X0, Y0, X1, Y1;
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
    annotation_entry *Annotations;
    int AnnotationCount;
    int MaxAnnotations;
    int IsAnnotating;
    int CurrentAnnotationIndex;

    int IsCensoring;
    int CensorStartX;
    int CensorStartY;
};

static void SelectionReset(selection_state *Selection);
static void SelectionBegin(selection_state *Selection, int X, int Y);
static void SelectionUpdate(selection_state *Selection, int X, int Y);
static void SelectionEnd(selection_state *Selection);
static RECT SelectionGetRect(selection_state *Selection);
static void SelectionSetRect(selection_state *Selection, RECT R);

static void AnnotationInit(selection_state *Selection, memory_arena *Arena);
static void AnnotationBegin(selection_state *Selection, memory_arena *Arena, int X, int Y);
static void AnnotationUpdate(selection_state *Selection, int X, int Y);
static void AnnotationEnd(selection_state *Selection);
static void AnnotationUndo(selection_state *Selection);

static void CensorBegin(selection_state *Selection, int X, int Y);
static void CensorUpdate(selection_state *Selection, int X, int Y);
static void CensorEnd(selection_state *Selection);
