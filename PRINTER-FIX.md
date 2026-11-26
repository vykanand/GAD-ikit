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

## Verification

1. Print one 13-digit barcode from the app.
2. Measure a single module: it must be ~3 dots (≈0.375 mm), not ~6–7 dots.
3. The symbol must fit inside the 58.42 mm width with quiet zones intact.
4. Scan the printed label with the app's scanner — it must decode on the first pass.

## Files Involved

- `scripts/tsc-print-calibration.ps1` — GDI+ `PrintPage` handler (the fix lives here).
- `main.js` — `printBarcode()` builds PowerShell args and invokes the script.
- `barcode-display.js` — renderer → `ipcRenderer.invoke('print-barcode', { barcode })`.
