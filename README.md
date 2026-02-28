# BetterSS

A screenshot tool for Windows that does the job without the bloat.

Region capture, window snapping, annotations, censor rectangles, clipboard copy, and file save.

## Why

Microsoft's Snipping Tool fires ~15 ETW telemetry events per screenshot. It writes a temp PNG and a JSON metadata file to disk before the image even reaches your clipboard.  Its ViewModel constructor does mass heap allocations, 8 COM activations, 5 event subscriptions, 8 separate memset calls, and 14 vtable assignments... just to set up state... for ONLY screenshots.. that's not even including the annotation CoPilot BS that comes with it.
The ratio of ceremony to actual work is insane.

## How It Works

On hotkey press (you can configure this in the tray icon context menu), BetterSS uses DXGI to grab the desktop framebuffer directly from the GPU, you can then select a region to capture. If you hold Shift during capture you can snap the selection to window boundaries.

Right click drag will draw freehand red lines and Shift + right click drag will draw a filled rectangle box. Middle click or Ctrl+Z undoes the last annotation.

Default hotkeys are Ctrl+Shift+S to capture to your clipboard and Ctrl+Shift+Alt+S to capture to a file.  Both are configurable from the tray icon.

Escape cancels the capture.  

## Building

Requires Visual Studio build tools and the Windows SDK.  You can build it via a developer command prompt via the `build.bat` file.  Output goes to `build\betterss.exe`