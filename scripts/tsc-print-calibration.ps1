# Draw CustomerKitPartcode on the left side under barcode
# Use a dedicated text margin (30 dots ≈ 3.7 mm) so the printer's internal margins don't clip the text at the label edges.
$partCodeX = 30
$graphics.DrawString($partCodeText, $codeFont, $black, $partCodeX, $codeTextY)

# Draw date on the right side under barcode, right-aligned to the margin
$dateRight = $widthDots - 60
$dateHeightDots = 24
$dateRect = [System.Drawing.RectangleF]::new($dateRight - 200, $codeTextY, 200, $dateHeightDots)
$stringFormat = [System.Drawing.StringFormat]::new()
$stringFormat.Alignment = [System.Drawing.StringAlignment]::Far
$graphics.DrawString($dateText, $codeFont, $black, $dateRect, $stringFormat)