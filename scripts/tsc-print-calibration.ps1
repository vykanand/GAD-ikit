[CmdletBinding()]
param(
  [string]$PrinterName,
  [string]$Barcode,
  [ValidateRange(3.0, 5.0)]
  [double]$ModuleDots = 4.0,
  [ValidateRange(50, 100)]
  [int]$BarHeightPercent = 100,
  [ValidateRange(-1.5, 1.5)]
  [double]$OffsetXmm = 0,
  [ValidateRange(-1.5, 1.5)]
  [double]$OffsetYmm = 0,
  [switch]$AutoFit,
  [int]$ExpectedWidthHundredthInch,
  [int]$ExpectedHeightHundredthInch,
  [int]$ExpectedDpiX,
  [int]$ExpectedDpiY,
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

function Get-ValidEan13 {
  $digits = -join (1..12 | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 })
  $sum = 0
  for ($index = 0; $index -lt 12; $index++) {
    $digit = [int]::Parse($digits[$index].ToString())
    $sum += if (($index % 2) -eq 0) { $digit } else { $digit * 3 }
  }
  $checkDigit = (10 - ($sum % 10)) % 10
  return "$digits$checkDigit"
}

function Test-Ean13Checksum([string]$Code) {
  if ($Code -notmatch '^\d{13}$') { return $false }
  $sum = 0
  for ($index = 0; $index -lt 12; $index++) {
    $digit = [int]::Parse($Code[$index].ToString())
    $sum += if (($index % 2) -eq 0) { $digit } else { $digit * 3 }
  }
  return ((10 - ($sum % 10)) % 10) -eq [int]::Parse($Code[12].ToString())
}

function Get-Ean13Pattern([string]$Code) {
  $leftOdd = @(
    '0001101', '0011001', '0010011', '0111101', '0100011',
    '0110001', '0101111', '0111011', '0110111', '0001011'
  )
  $leftEven = @(
    '0100111', '0110011', '0011011', '0100001', '0011101',
    '0111001', '0000101', '0010001', '0001001', '0010111'
  )
  $right = @(
    '1110010', '1100110', '1101100', '1000010', '1011100',
    '1001110', '1010000', '1000100', '1001000', '1110100'
  )
  $parityByFirstDigit = @(
    'LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG',
    'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL'
  )

  if (-not (Test-Ean13Checksum $Code)) { throw 'Barcode must be a valid EAN-13 code with a correct check digit.' }

  $pattern = '101'
  $parity = $parityByFirstDigit[[int]::Parse($Code[0].ToString())]
  for ($index = 1; $index -le 6; $index++) {
    $digit = [int]::Parse($Code[$index].ToString())
    $pattern += if ($parity[$index - 1] -eq 'L') { $leftOdd[$digit] } else { $leftEven[$digit] }
  }
  $pattern += '01010'
  for ($index = 7; $index -le 12; $index++) {
    $pattern += $right[[int]::Parse($Code[$index].ToString())]
  }
  $pattern += '101'
  if ($pattern.Length -ne 95) { throw 'EAN-13 pattern length is invalid.' }
  return $pattern
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
$paper = $document.DefaultPageSettings.PaperSize
$resolution = $document.DefaultPageSettings.PrinterResolution
if ($paper.Width -le 0 -or $paper.Height -le 0) { throw 'Driver did not report a valid default label size.' }
if ($resolution.X -le 0 -or $resolution.Y -le 0) { throw 'Driver did not report a valid print resolution.' }
if (($ExpectedWidthHundredthInch -gt 0 -and $paper.Width -ne $ExpectedWidthHundredthInch) -or
    ($ExpectedHeightHundredthInch -gt 0 -and $paper.Height -ne $ExpectedHeightHundredthInch) -or
    ($ExpectedDpiX -gt 0 -and $resolution.X -ne $ExpectedDpiX) -or
    ($ExpectedDpiY -gt 0 -and $resolution.Y -ne $ExpectedDpiY)) {
  throw 'Printer media or resolution changed after the app detected it. Refresh media and try again.'
}

$widthDots = [int][Math]::Round($paper.Width * $resolution.X / 100, [MidpointRounding]::AwayFromZero)
$heightDots = [int][Math]::Round($paper.Height * $resolution.Y / 100, [MidpointRounding]::AwayFromZero)
$outerMarginDots = [Math]::Max(2, [int][Math]::Round($resolution.X / 25.4 * 0.25, [MidpointRounding]::AwayFromZero))
$maxModuleDots = [Math]::Min(5.0, ($widthDots - 2 * $outerMarginDots) / 113.0)
$effectiveModuleDots = if ($AutoFit) { $maxModuleDots } else { [Math]::Min($ModuleDots, $maxModuleDots) }
if ($effectiveModuleDots -lt 3) { throw 'The detected label is too narrow for a reliably scannable EAN-13 barcode.' }

$barHeightDots = [int][Math]::Floor(($heightDots - 2 * $outerMarginDots) * $BarHeightPercent / 100.0)
$left = [int][Math]::Round(($widthDots - 113 * $effectiveModuleDots) / 2.0 + $OffsetXmm * $resolution.X / 25.4, [MidpointRounding]::AwayFromZero)
$top = [int][Math]::Round(($heightDots - $barHeightDots) / 2.0 + $OffsetYmm * $resolution.Y / 25.4, [MidpointRounding]::AwayFromZero)
if ($left -lt $outerMarginDots -or $top -lt $outerMarginDots -or
    ($left + 113 * $effectiveModuleDots) -gt ($widthDots - $outerMarginDots) -or
    ($top + $barHeightDots) -gt ($heightDots - $outerMarginDots)) {
  throw 'Barcode does not fit the active label with these settings.'
}

$settings = [ordered]@{
  printerName       = $PrinterName
  autoFit           = [bool]$AutoFit
  moduleDots        = $ModuleDots
  barHeightPercent  = $BarHeightPercent
  offsetXmm         = $OffsetXmm
  offsetYmm         = $OffsetYmm
  mediaFitVersion   = 4
}

if ($Inspect) {
  $testBarcode = Get-ValidEan13
  $testPattern = Get-Ean13Pattern $testBarcode
  Write-Host "Printer: $PrinterName"
  Write-Host "Media: $($paper.PaperName), $($paper.Width * 0.254) x $($paper.Height * 0.254) mm, $($resolution.X) x $($resolution.Y) dpi"
  Write-Host "Raster: $widthDots x $heightDots dots | fitted module width: $([Math]::Round($effectiveModuleDots, 2)) dots"
  Write-Host "Barcode encoder: valid EAN-13, $($testPattern.Length) modules."
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

if (-not $Barcode) { $Barcode = Get-ValidEan13 }
$barcode = $Barcode
$pattern = Get-Ean13Pattern $barcode
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

try {
  for ($module = 0; $module -lt 95; $module++) {
    if ($pattern[$module] -ne '1') { continue }
    $x1 = $left + [int][Math]::Round((11 + $module) * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
    $x2 = $left + [int][Math]::Round((12 + $module) * $effectiveModuleDots, [MidpointRounding]::AwayFromZero)
    $graphics.FillRectangle($black, $x1, $top, [Math]::Max(1, $x2 - $x1), $barHeightDots)
  }

  $document.DefaultPageSettings.Margins = [System.Drawing.Printing.Margins]::new(0, 0, 0, 0)
  $document.OriginAtMargins = $false
  $document.PrinterSettings.Copies = 1
  $document.PrintController = [System.Drawing.Printing.StandardPrintController]::new()
  $printHandler = [System.Drawing.Printing.PrintPageEventHandler]{
    param($sender, $eventArgs)
    $eventArgs.Graphics.PageUnit = [System.Drawing.GraphicsUnit]::Display
    $eventArgs.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $eventArgs.Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $eventArgs.Graphics.DrawImage(
      $bitmap,
      [System.Drawing.Rectangle]::new(0, 0, $paper.Width, $paper.Height)
    )
    $eventArgs.HasMorePages = $false
  }
  $document.add_PrintPage($printHandler)
  try {
    if (-not $Print) {
      throw 'Add -Print to submit exactly one label.'
    }
    Write-Host "Printer: $PrinterName"
    Write-Host "Media: $($paper.PaperName), $($paper.Width * 0.254) x $($paper.Height * 0.254) mm, $($resolution.X) x $($resolution.Y) dpi"
    Write-Host "Barcode: $barcode | module width: $([Math]::Round($effectiveModuleDots, 2)) dots | bar height: $barHeightDots dots"
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
  $black.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
  $document.Dispose()
}
