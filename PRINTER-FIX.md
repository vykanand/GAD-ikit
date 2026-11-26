# Barcode Printer Fix — Root Cause

Status: **working and verified**. Bars print thin, sharp, fit the label, and scan reliably.
Do not change the print rendering path unless you reproduce the failure below.

## Symptom

- Barcodes printed from the app had **bars roughly 2× too thick**.
- The raster **overflowed the 58.42 × 14.986 mm label** (bars clipped at the edges).
- Printed barcodes were **not scannable**; the on-screen preview looked correct.
- Label/printer: 203 DPI thermal, 58.42 × 14.986 mm → native raster **467 × 120 dots**.

## Root Cause

In `scripts/tsc-print-calibration.ps1` the `PrintPage` handler used:

```powershell
$eventArgs.Graphics.PageUnit = [System.Drawing.GraphicsUnit]::Display
$eventArgs.Graphics.DrawImage(
  $bitmap,
  [System.Drawing.Rectangle]::new(0, 0, $paper.Width, $paper.Height)
)
```

- `GraphicsUnit.Display` means **1 graphics unit = 1/96 inch**.
- The printer runs at **203 DPI**.
- Scaling ratio = `203 / 96 ≈ 2.115`.
- The destination rectangle was sized in **device dots** (`$paper.Width` / `$paper.Height`,
  i.e. 467 × 120) but interpreted in **1/96 inch** units, so the 467 × 120 raster was
  blown up ~2.1×. Each 3-dot module became ~6–7 dots → fat, merged bars, overflow,
  and an unscannable symbol.

The barcode raster itself was correct all along. Only the GDI+ blit scale was wrong.

## Fix (current, working)

```powershell
$eventArgs.Graphics.PageUnit = [System.Drawing.GraphicsUnit]::Pixel
$eventArgs.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$eventArgs.Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$eventArgs.Graphics.DrawImageUnscaled($bitmap, 0, 0)
```

Why this works:

- `GraphicsUnit.Pixel` maps **1 graphics unit = 1 printer device dot** at native 203 DPI.
- `DrawImageUnscaled($bitmap, 0, 0)` blits the 467 × 120 raster **1:1** with no scaling.
- `PixelOffsetMode.Half` keeps module edges on the pixel grid (no half-pixel blur/thickening).
- `InterpolationMode.NearestNeighbor` guarantees no smoothing if any resample ever occurs.

The working version also does **not** force
`$document.PrintController = [System.Drawing.Printing.StandardPrintController]::new()`.

## Invariants — do not break

- Label geometry: **58.42 × 14.986 mm at 203 DPI = 467 × 120 dots**.
- Module width: **3 dots** (`-ModuleDots 3`), bar height **108 dots** (`-BarHeightPercent 100`).
- Keep `GraphicsUnit.Pixel` + `DrawImageUnscaled`. Reverting to `Display` + `DrawImage`
  with a dot-sized rectangle reintroduces the ~2.1× upscale.
- Do not change `barcode-display.js` printing call (`invoke('print-barcode', { barcode })`)
  or the `main.js` print handler when touching unrelated features.

## Module width must be a whole number of dots

Even with a perfect 1:1 blit, a **fractional** module width breaks scanning.
At 2.59 dots/module each bar and space rasterises to 2 or 3 dots, so the
Code 128 bar ratios are wrong (a 3-dot bar next to a 2-dot space reads as
1.5:1 instead of 1:1) and scanners fail. The raster looks fine to the eye.

- Always `Floor()` the fitted module width to an integer, minimum 2 dots.
- If a payload does not fit at 3 dots, shrink the **symbol**, not the module:
  encode runs of 4+ digits in Code Set C so e.g. `EAD64745024` stays at
  123 modules (same as a 13-digit numeric code) and prints at 3 dots.
- 11-char all-letter payloads cannot fit 3 dots on a 58.42 mm / 203 DPI label
  (156 modules); they fall back to uniform 2-dot modules.

## Verification

1. Print one 13-digit barcode from the app.
2. Measure a single module: it must be ~3 dots (≈0.375 mm), not ~6–7 dots.
3. The symbol must fit inside the 58.42 mm width with quiet zones intact.
4. Scan the printed label with the app's scanner — it must decode on the first pass.

## Files Involved

- `scripts/tsc-print-calibration.ps1` — GDI+ `PrintPage` handler (the fix lives here).
- `main.js` — `printBarcode()` builds PowerShell args and invokes the script.
- `barcode-display.js` — renderer → `ipcRenderer.invoke('print-barcode', { barcode })`.
