[CmdletBinding()]
param(
  [string]$PrinterName,
  [string]$Barcode,
  [string]$BarcodePattern,
  [ValidateRange(3.0, 5.0)]
  [double]$ModuleDots = 3.0,
  [ValidateRange(0.25, 2.0)]
  [double]$BorderMarginMm = 0.75,
  [ValidateRange(50, 100)]
  [int]$BarHeightPercent = 100,
  [ValidateRange(-1.5, 1.5)]
  [double]$OffsetXmm = 0,
  [ValidateRange(-1.5, 1.5)]
  [double]$OffsetYmm = 0,
  [switch]$AutoFit,
  [int]$ExpectedWidthHundredthInch,
  [int]$ExpectedHeightHundredthInch,
  [int]$LabelWidthHundredthInch,
  [int]$LabelHeightHundredthInch,
  [int]$ExpectedDpiX,
  [int]$ExpectedDpiY,
  [int]$DarknessLevel = -1,
  [switch]$AllowOtherPrinter,
  [string]$ConfigPath = (Join-Path $env:APPDATA 'gad-qr-scanner\print-test-settings.json'),
  [switch]$Inspect,
  [switch]$Print,
  [switch]$SaveApproved
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$actionCount = [int]$Inspect.IsPresent + [int]$Print.IsPresent + [int]$SaveApproved.IsPresent
if ($actionCount -ne 1) {
  throw 'Choose exactly one action: -Inspect, -Print, or -SaveApproved.'
}

Add-Type -AssemblyName System.Drawing

function Get-ValidPayload {
  $digits = -join (1..12 | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 })
  $sum = 0
  $multiplyByThree = $true
  for ($index = 11; $index -ge 0; $index--) {
    $digit = [int]::Parse($digits[$index].ToString())
    if ($multiplyByThree) { $digit *= 3 }
    $sum += $digit
    $multiplyByThree = -not $multiplyByThree
  }
  $checkDigit = (10 - ($sum % 10)) % 10
  return "$digits$checkDigit"
}

function Test-PayloadCheckDigit([string]$Code) {
  if ($Code -notmatch '^\d{13}$') { return $false }
  $sum = 0
  $multiplyByThree = $true
  for ($index = 11; $index -ge 0; $index--) {
    $digit = [int]::Parse($Code[$index].ToString())
    if ($multiplyByThree) { $digit *= 3 }
    $sum += $digit
    $multiplyByThree = -not $multiplyByThree
  }
  return ((10 - ($sum % 10)) % 10) -eq [int]::Parse($Code[12].ToString())
}

function Get-Code128Pattern([string]$Code) {
  $patterns = @(
    '11011001100', '11001101100', '11001100110', '10010011000', '10010001100',
    '10001001100', '10011001000', '10011000100', '10001100100', '11001001000',
    '11001000100', '11000100100', '10110011100', '10011011100', '10011001110',
    '10111001100', '10011101100', '10011100110', '11001110010', '11001011100',
    '11001001110', '11011100100', '11001110100', '11101101110', '11101001100',
    '11100101100', '11100100110', '11101100100', '11100110100', '11100110010',
    '11011011000', '11011000110', '11000110110', '10100011000', '10001011000',
    '10001000110', '10110001000', '10001101000', '10001100010', '11010001000',
    '11000101000', '11000100010', '10110111000', '10110001110', '10001101110',
    '10111011000', '10111000110', '10001110110', '11101110110', '11010001110',
    '11000101110', '11011101000', '11011100010', '11011101110', '11101011000',
    '11101000110', '11100010110', '11101101000', '11101100010', '11100011010',
    '11101111010', '11001000010', '11110001010', '10100110000', '10100001100',
    '10010110000', '10010000110', '10000101100', '10000100110', '10110010000',
    '10110000100', '10011010000', '10011000010', '10000110100', '10000110010',
    '11000010010', '11001010000', '11110111010', '11000010100', '10001111010',
    '10100111100', '10010111100', '10010011110', '10111100100', '10011110100',
    '10011110010', '11110100100', '11110010100', '11110010010', '11011011110',
    '11011110110', '11110110110', '10101111000', '10100011110', '10001011110',
    '10111101000', '10111100010', '11110101000', '11110100010', '10111011110',
    '10111101110', '11101011110', '11110101110', '11010000100', '11010010000',
    '11010011100', '1100011101011'
  )
  if ($Code -match '^\d{13}$') {
    if (-not (Test-PayloadCheckDigit $Code)) { throw 'Barcode must be a valid 13-digit numeric code with a correct check digit.' }

    $codewords = [System.Collections.Generic.List[int]]::new()
    $codewords.Add(104)
    $codewords.Add([int]::Parse($Code[0].ToString()) + 16)
    $codewords.Add(99)
    for ($index = 1; $index -lt $Code.Length; $index += 2) {
      $codewords.Add([int]::Parse($Code.Substring($index, 2)))
    }
    $checksum = $codewords[0]
    for ($index = 1; $index -lt $codewords.Count; $index++) {
      $checksum += $codewords[$index] * $index
    }
    $checksum %= 103
    $pattern = ''
    foreach ($codeword in $codewords) { $pattern += $patterns[$codeword] }
    return $pattern + $patterns[$checksum] + $patterns[106]
  }

  # Code 128 auto mode for printable ASCII payloads (e.g. part codes like
  # EAD64745024). Runs of 4+ digits use Code Set C so the symbol stays at
  # 123 modules and prints with uniform 3-dot modules.
  if ([string]::IsNullOrEmpty($Code)) { throw 'Barcode payload must not be empty.' }
  if ($Code.Length -gt 80) { throw 'Barcode payload is too long for Code 128.' }
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($Code)
  foreach ($byte in $bytes) {
    if ($byte -lt 32 -or $byte -gt 126) {
      throw 'Barcode payload must contain printable ASCII characters only.'
    }
  }

  $codewords = [System.Collections.Generic.List[int]]::new()
  $codewords.Add(104) # START B
  $set = 'B'
  $index = 0
  while ($index -lt $Code.Length) {
    $charCode = [int][char]$Code[$index]
    $isDigit = $charCode -ge 48 -and $charCode -le 57

    if (-not $isDigit) {
      if ($set -ne 'B') { $codewords.Add(100); $set = 'B' }
      $codewords.Add($charCode - 32)
      $index += 1
      continue
    }

    $end = $index
    while ($end -lt $Code.Length) {
      $next = [int][char]$Code[$end]
      if ($next -lt 48 -or $next -gt 57) { break }
      $end += 1
    }
    $run = $end - $index

    if ($run -ge 4) {
      if (($run % 2) -eq 1) {
        if ($set -ne 'B') { $codewords.Add(100); $set = 'B' }
        $codewords.Add([int][char]$Code[$index] - 32)
        $index += 1
        $run -= 1
      }
      if ($set -ne 'C') { $codewords.Add(99); $set = 'C' }
      for ($offset = 0; $offset -lt $run; $offset += 2) {
        $codewords.Add([int]::Parse($Code.Substring($index + $offset, 2)))
      }
      $index += $run
    }
    else {
      if ($set -ne 'B') { $codewords.Add(100); $set = 'B' }
      for ($offset = 0; $offset -lt $run; $offset += 1) {
        $codewords.Add([int][char]$Code[$index + $offset] - 32)
      }
      $index += $run
    }
  }

  $checksum = $codewords[0]
  for ($index = 1; $index -lt $codewords.Count; $index++) {
    $checksum += $codewords[$index] * $index
  }
  $checksum %= 103
  $pattern = ''
  foreach ($codeword in $codewords) { $pattern += $patterns[$codeword] }
  return $pattern + $patterns[$checksum] + $patterns[106]
}

function Set-TscDarkness([string]$Name, [int]$Level) {
  if ($Level -lt 0 -or $Level -gt 15) {
    throw 'TSC darkness must be between 0 and 15.'
  }
  $configuration = Get-PrintConfiguration -PrinterName $Name -ErrorAction Stop
  if (-not $configuration.PrintTicketXML) {
    throw 'The printer driver did not provide a PrintTicket for darkness configuration.'
  }
  [xml]$ticket = $configuration.PrintTicketXML
  $darknessValue = $ticket.SelectSingleNode(
    "//*[local-name()='ParameterInit' and @name='seagull.driver.printer.tsc:JobDarknessLevel']/*[local-name()='Value']"
  )
  if (-not $darknessValue) {
    throw 'The selected printer driver does not expose a TSC darkness setting.'
  }
  $useCurrentOption = $ticket.SelectSingleNode(
    "//*[local-name()='Feature' and @name='seagull.driver.printer.tsc:JobUseCurrentPrinterSettings']/*[local-name()='Option']"
  )
  if ($useCurrentOption) {
    $useCurrentOption.SetAttribute('name', 'seagull.driver.printer.tsc:OptNo')
  }
  $commonDarknessValue = $ticket.SelectSingleNode(
    "//*[local-name()='Feature' and @name='seagull.driver.base:JobCommonValueDefinitions']/*[local-name()='Option']/*[local-name()='ScoredProperty' and @name='seagull.driver.base:Ptxcn_PrintDarkness']/*[local-name()='Value']"
  )
  $darknessValue.InnerText = [string]$Level
  if ($commonDarknessValue) {
    $commonDarknessValue.InnerText = "$([int][Math]::Round($Level * 100.0 / 15, [MidpointRounding]::AwayFromZero)) pct"
  }

  Set-PrintConfiguration -PrinterName $Name -PrintTicketXml $ticket.OuterXml -ErrorAction Stop | Out-Null
  $verified = Get-PrintConfiguration -PrinterName $Name -ErrorAction Stop
  [xml]$verifiedTicket = $verified.PrintTicketXML
  $verifiedValue = $verifiedTicket.SelectSingleNode(
    "//*[local-name()='ParameterInit' and @name='seagull.driver.printer.tsc:JobDarknessLevel']/*[local-name()='Value']"
  )
  if (-not $verifiedValue -or [int]$verifiedValue.InnerText -ne $Level) {
    throw 'Windows printer driver did not retain the requested darkness setting.'
  }
}

$installedPrinters = @([System.Drawing.Printing.PrinterSettings]::InstalledPrinters)
if (-not $PrinterName) {
  $defaultPrinter = Get-CimInstance Win32_Printer | Where-Object { $_.Default } | Select-Object -First 1
  if (-not $defaultPrinter) { throw 'Windows has no default printer.' }
  $PrinterName = $defaultPrinter.Name
}
if ($installedPrinters -notcontains $PrinterName) {
  throw "Printer is not installed: $PrinterName"
}
if (-not $AllowOtherPrinter -and $PrinterName -notmatch '(?i)(TSC.*244|244.*TSC)') {
  throw "Refusing to print to non-TSC-244 printer '$PrinterName'. Specify the TSC TTP-244 Pro printer."
}

$document = [System.Drawing.Printing.PrintDocument]::new()
$document.PrinterSettings.PrinterName = $PrinterName
if (-not $document.PrinterSettings.IsValid) { throw "Printer is unavailable: $PrinterName" }
if (($LabelWidthHundredthInch -gt 0) -or ($LabelHeightHundredthInch -gt 0)) {
  if ($LabelWidthHundredthInch -lt 39 -or $LabelWidthHundredthInch -gt 410 -or
      $LabelHeightHundredthInch -lt 20 -or $LabelHeightHundredthInch -gt 1181) {
    throw 'Custom label size is outside the supported range.'
  }
  try {
    $document.DefaultPageSettings.PaperSize = [System.Drawing.Printing.PaperSize]::new(
      'App custom label',
      $LabelWidthHundredthInch,
      $LabelHeightHundredthInch
    )
  }
  catch {
    throw "Printer driver rejected the app's custom label size: $($_.Exception.Message)"
  }
}
$paper = $document.DefaultPageSettings.PaperSize
$resolution = $document.DefaultPageSettings.PrinterResolution
if ($paper.Width -le 0 -or $paper.Height -le 0) { throw 'Driver did not report a valid default label size.' }
if (($LabelWidthHundredthInch -gt 0 -and $paper.Width -ne $LabelWidthHundredthInch) -or
    ($LabelHeightHundredthInch -gt 0 -and $paper.Height -ne $LabelHeightHundredthInch)) {
  throw 'Printer driver did not retain the app custom label size for this job.'
}
if ($resolution.X -le 0 -or $resolution.Y -le 0) { throw 'Driver did not report a valid print resolution.' }

$widthDots = [int][Math]::Round($paper.Width * $resolution.X / 100, [MidpointRounding]::AwayFromZero)
$heightDots = [int][Math]::Round($paper.Height * $resolution.Y / 100, [MidpointRounding]::AwayFromZero)
$outerMarginXDots = [Math]::Max(2, [int][Math]::Round($resolution.X / 25.4 * $BorderMarginMm, [MidpointRounding]::AwayFromZero))
$outerMarginYDots = [Math]::Max(2, [int][Math]::Round($resolution.Y / 25.4 * $BorderMarginMm, [MidpointRounding]::AwayFromZero))
$quietZoneModules = 10
if (-not $Barcode) { $Barcode = Get-ValidPayload }
$expectedPattern = Get-Code128Pattern $Barcode
if ($BarcodePattern -and $BarcodePattern -cne $expectedPattern) {
  throw 'Code 128 pattern does not match the requested numeric barcode.'
}
$pattern = $expectedPattern
$totalModules = $pattern.Length + $quietZoneModules * 2
$maxModuleDots = [Math]::Min(5.0, ($widthDots - 2 * $outerMarginXDots) / $totalModules)
$effectiveModuleDots = if ($AutoFit) { $maxModuleDots } else { [Math]::Min($ModuleDots, $maxModuleDots) }
# Whole-dot modules only: a fractional width makes bars alternate 2/3 dots and
# breaks the Code 128 bar ratios even though the raster itself is 1:1.
$effectiveModuleDots = [Math]::Floor($effectiveModuleDots)
if ($effectiveModuleDots -lt 2) { throw 'The detected label is too narrow for a reliably scannable Code 128 barcode.' }
if ($effectiveModuleDots -lt 3) {
  Write-Warning ("Module width {0:N2} dots is below the 3-dot preference because the payload is long for this label. The raster is still blitted 1:1 at 203 DPI." -f $effectiveModuleDots)
}

$barHeightDots = [int][Math]::Floor(($heightDots - 2 * $outerMarginYDots) * $BarHeightPercent / 100.0)
$blockWidthDots = [int][Math]::Round($totalModules * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
$left = [int][Math]::Round(($widthDots - $blockWidthDots) / 2.0 + $OffsetXmm * $resolution.X / 25.4, [MidpointRounding]::AwayFromZero)
$top = [int][Math]::Round(($heightDots - $barHeightDots) / 2.0 + $OffsetYmm * $resolution.Y / 25.4, [MidpointRounding]::AwayFromZero)
if ($left -lt $outerMarginXDots -or $top -lt $outerMarginYDots -or
    ($left + $blockWidthDots) -gt ($widthDots - $outerMarginXDots) -or
    ($top + $barHeightDots) -gt ($heightDots - $outerMarginYDots)) {
  throw 'Barcode does not fit the active label with these settings.'
}

$settings = [ordered]@{
  printerName       = $PrinterName
  mediaWidthMm      = $paper.Width * 0.254
  mediaHeightMm     = $paper.Height * 0.254
  borderMarginMm    = $BorderMarginMm
  autoFit           = [bool]$AutoFit
  moduleDots        = $ModuleDots
  barHeightPercent  = $BarHeightPercent
  offsetXmm         = $OffsetXmm
  offsetYmm         = $OffsetYmm
  applyDarkness     = $DarknessLevel -ge 0
  darknessLevel     = if ($DarknessLevel -ge 0) { $DarknessLevel } else { 7 }
  mediaFitVersion   = 4
}

if ($Inspect) {
  Write-Host "Printer: $PrinterName"
  Write-Host "Media: $($paper.PaperName), $($paper.Width * 0.254) x $($paper.Height * 0.254) mm, $($resolution.X) x $($resolution.Y) dpi"
  Write-Host "Raster: $widthDots x $heightDots dots | border margin: $BorderMarginMm mm | fitted module width: $([Math]::Round($effectiveModuleDots, 2)) dots | bar height: $barHeightDots dots"
  Write-Host "Barcode: $Barcode | Code 128, $($pattern.Length) modules."
  $document.Dispose()
  return
}

if ($SaveApproved) {
  $directory = Split-Path -Parent $ConfigPath
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $json = $settings | ConvertTo-Json
  [System.IO.File]::WriteAllText(
    $ConfigPath,
    $json,
    [System.Text.UTF8Encoding]::new($false)
  )
  Write-Host "Approved settings saved: $ConfigPath"
  $document.Dispose()
  exit 0
}

$barcode = $Barcode

Write-Host "Starting print script for barcode: $barcode"
$bitmap = [System.Drawing.Bitmap]::new(
  $widthDots,
  $heightDots,
  [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
)
$bitmap.SetResolution([single]$resolution.X, [single]$resolution.Y)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$graphics.Clear([System.Drawing.Color]::White)
$black = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::Black)

# Human-readable text under the barcode: CustomerKitPartcode on left, date on right
$codeFont = [System.Drawing.Font]::new('Arial', 7, [System.Drawing.FontStyle]::Bold)
$partCodeText = $barcode
$dateText = (Get-Date -Format "dd/MM/yy")

$partCodeSize = $graphics.MeasureString($partCodeText, $codeFont)
$dateSize = $graphics.MeasureString($dateText, $codeFont)

# Reserve space for text so barcode never overlaps it.
$textPadDots = 4
$textBlockDots = [int][Math]::Max($partCodeSize.Height, $dateSize.Height) + $textPadDots

# Barcode takes most of the label (tall bars, scannable), text small at bottom.
$drawBarHeight = [int][Math]::Max(40, $heightDots - 2 * $outerMarginYDots - $textBlockDots)
if ($drawBarHeight -gt $barHeightDots) { $drawBarHeight = $barHeightDots }
$barcodeY = $outerMarginYDots
$codeTextY = $barcodeY + $drawBarHeight + $textPadDots

try {
  # Draw barcode pattern
  for ($module = 0; $module -lt $pattern.Length; $module++) {
    if ($pattern[$module] -ne '1') { continue }
    $x1 = $left + [int][Math]::Round(($quietZoneModules + $module) * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
    $x2 = $left + [int][Math]::Round(($quietZoneModules + $module + 1) * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
    $graphics.FillRectangle($black, $x1, $barcodeY, [Math]::Max(1, $x2 - $x1), $drawBarHeight)
  }

  # Keep both bottom labels inside the printed bars, inset from each corner.
  $barcodeLeft = $left + [int][Math]::Round($quietZoneModules * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
  $barcodeRight = $left + [int][Math]::Round(($quietZoneModules + $pattern.Length) * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
  $textInsetDots = 20
  $textGapDots = 8
  $textLeft = $barcodeLeft + $textInsetDots
  $textRight = $barcodeRight - $textInsetDots
  $partCodeWidth = [int][Math]::Ceiling($partCodeSize.Width)
  $dateWidth = [int][Math]::Ceiling($dateSize.Width)
  if (($textRight - $textLeft) -lt ($partCodeWidth + $dateWidth + $textGapDots)) {
    throw 'Customer part code and date do not fit within the barcode width with the required padding.'
  }

  $partCodeRect = [System.Drawing.RectangleF]::new($textLeft, $codeTextY, $partCodeWidth, $textBlockDots)
  $dateRect = [System.Drawing.RectangleF]::new($textRight - $dateWidth, $codeTextY, $dateWidth, $textBlockDots)
  $stringFormat = [System.Drawing.StringFormat]::new()
  $stringFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
  try {
    $stringFormat.Alignment = [System.Drawing.StringAlignment]::Near
    $graphics.DrawString($partCodeText, $codeFont, $black, $partCodeRect, $stringFormat)

    # Align the date to the inset at the opposite barcode edge.
    $stringFormat.Alignment = [System.Drawing.StringAlignment]::Far
    $graphics.DrawString($dateText, $codeFont, $black, $dateRect, $stringFormat)
  }
  finally {
    $stringFormat.Dispose()
  }

  $document.DefaultPageSettings.Margins = [System.Drawing.Printing.Margins]::new(0, 0, 0, 0)
  $document.OriginAtMargins = $false
  $document.PrinterSettings.Copies = 1
  $printHandler = [System.Drawing.Printing.PrintPageEventHandler]{
    param($sender, $eventArgs)
    # PageUnit.Pixel maps 1 graphics unit to 1 printer device dot, so the
    # raster is blitted 1:1 at native 203 DPI resolution (no scaling, no
    # bar thickening). Using Display (1/96in) here would scale the image.
    $eventArgs.Graphics.PageUnit = [System.Drawing.GraphicsUnit]::Pixel
    $eventArgs.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $eventArgs.Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $eventArgs.Graphics.DrawImageUnscaled($bitmap, 0, 0)
    Write-Host "PrintPage event fired - drawing bitmap"
    $eventArgs.HasMorePages = $false
  }
  $document.add_PrintPage($printHandler)
  try {
    if (-not $Print) {
      throw 'Add -Print to submit exactly one label.'
    }
    if ($DarknessLevel -ge 0) {
      Set-TscDarkness -Name $PrinterName -Level $DarknessLevel
    }
    Write-Host "Printer: $PrinterName"
    Write-Host "Media: $($paper.PaperName), $($paper.Width * 0.254) x $($paper.Height * 0.254) mm, $($resolution.X) x $($resolution.Y) dpi"
    Write-Host "Barcode: $barcode | Code 128 | module width: $([Math]::Round($effectiveModuleDots, 2)) dots | bar height: $barHeightDots dots"
    Write-Host 'Submitting exactly one test label...'
    $document.Print()
    Write-Host 'One label submitted. Review it, then use the feedback in chat before printing another.'
    Write-Host 'To save a user-approved result, rerun with the same settings and -SaveApproved (no print will be sent).'
  }
  finally {
    $document.remove_PrintPage($printHandler)
  }
}
finally {
  $codeFont.Dispose()
  $black.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
  $document.Dispose()
}