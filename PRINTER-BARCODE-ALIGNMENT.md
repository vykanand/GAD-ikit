# Printer Barcode and Text Alignment

This guide documents how the calibration script positions the barcode and its
human-readable text, and how the app sends a label to the printer.

## Files and print flow

- `barcode-display.js` requests printing through the `print-barcode` IPC channel.
- `main.js` validates the request, gets the configured printer media, and invokes
  `scripts/tsc-print-calibration.ps1`.
- The PowerShell script renders the barcode and text into a bitmap at the
  printer's reported DPI, then sends that bitmap to the Windows printer driver.
- In development, the app uses the script in the project directory. A packaged
  app uses the copy under its application resources, so packaged builds must be
  rebuilt to include script changes.

The success-modal Print button sends two print requests in sequence. Each request
prints one label.

## Alignment approach

All layout positions are measured in printer dots (bitmap pixels), not CSS pixels,
millimetres, or Windows `Display` units. The bitmap is assigned the printer's
resolution and printed with `GraphicsUnit.Pixel` and `DrawImageUnscaled`, keeping
the raster at 1:1 scale.

The barcode is centered as a complete Code 128 block, including its quiet zones.
The visible bar bounds are calculated separately:

```powershell
$barcodeLeft = $left + Round($quietZoneModules * $effectiveModuleDots)
$barcodeRight = $left + Round(($quietZoneModules + $pattern.Length) * $effectiveModuleDots)
```

Using these bounds anchors the text to the printed bars rather than the label's
outer edges or the larger quiet-zone block.

The bottom text layout then:

1. Insets both text edges by 20 printer dots (about 2.5 mm at 203 DPI).
2. Measures the part-code and date widths using the same graphics context and font
   used to draw them.
3. Keeps the part code left-aligned at the left inset and the date right-aligned
   at the right inset.
4. Requires at least 8 dots between the two strings. If their measured widths do
   not fit, printing stops with an explicit error instead of allowing overlap or
   drawing beyond the barcode bounds.
5. Uses `StringFormatFlags.NoWrap` so text stays on one line inside its assigned
   rectangle.

The barcode height reserves a text strip at the bottom. The text starts below the
bars, with the existing 4-dot vertical gap. The text font is not silently shrunk;
insufficient horizontal space is reported as an error.

## Core layout logic

Simplified version of the relevant script logic:

```powershell
$textInsetDots = 20
$textGapDots = 8
$textLeft = $barcodeLeft + $textInsetDots
$textRight = $barcodeRight - $textInsetDots
$partCodeWidth = [int][Math]::Ceiling($partCodeSize.Width)
$dateWidth = [int][Math]::Ceiling($dateSize.Width)

if (($textRight - $textLeft) -lt ($partCodeWidth + $dateWidth + $textGapDots)) {
  throw 'Customer part code and date do not fit within the barcode width with the required padding.'
}

$partCodeRect = [System.Drawing.RectangleF]::new(
  $textLeft, $codeTextY, $partCodeWidth, $textBlockDots
)
$dateRect = [System.Drawing.RectangleF]::new(
  $textRight - $dateWidth, $codeTextY, $dateWidth, $textBlockDots
)
```

The complete implementation is in
[`scripts/tsc-print-calibration.ps1`](./scripts/tsc-print-calibration.ps1).

## App media settings

The app supplies its configured media dimensions to the script. Its default
calibration media is 58.42 × 14.986 mm at 203 DPI. Running the PowerShell script
directly with `-Inspect` and no custom label dimensions instead reports the
Windows printer's default paper size, which may be different; that standalone
result does not represent the app's custom-media print request.

## Verification

- PowerShell syntax and whitespace checks passed after the layout change.
- A rendered sample confirmed both strings stayed inside the calculated barcode
  bounds and retained the configured insets and gap.
- The user confirmed the updated alignment approach worked.

For another physical check, use a successful scan and the success-modal Print
button. It prints two labels. Verify the text remains within the bars and that the
barcode remains scannable.
