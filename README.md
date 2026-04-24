# BetterSS

A screenshot tool for Windows that does the job without the bloat.

Region capture, window snapping, annotations, censor rectangles, clipboard copy, and file save.

## Why

Microsoft's Snipping Tool fires ~15 ETW telemetry events per screenshot. It writes a temp PNG and a JSON metadata file to disk before the image even reaches your clipboard.  Its ViewModel constructor does mass heap allocations, 8 COM activations, 5 event subscriptions, 8 separate memset calls, and 14 vtable assignments... just to set up state... for ONLY screenshots.. that's not even including the annotation CoPilot BS that comes with it.
The ratio of ceremony to actual work is insane.

## How It Works

On hotkey press (configurable from the tray icon), BetterSS uses DXGI to grab the desktop framebuffer directly from the GPU. On NVIDIA with elevated privileges, it uses NVAPI scanout for a faster capture path. You then select a region to capture. Hold Shift to snap the selection to window boundaries.

Three annotation modes, LINE, HIGHLIGHT and CENSOR switchable via 1/2/3 keys, mouse wheel, or the settings panel (tab). Right click drag draws with the currently active mode. hold ctrl while drawing to lock to an axis. middle click or ctrl+z undoes the last annotation.

Press tab to open the settings panel that has an HSV colour wheel, colour presets, brush width and stabilisation sliders

Escape cancels the capture.

## Building

you cant yet