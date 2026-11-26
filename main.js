const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const { execFile } = require('child_process');
const { promisify } = require('util');
const XLSX = require('xlsx');
const Code128Encoder = require('./code128-encoder');
const execFileAsync = promisify(execFile);

// Main-process debug gate. Set process.env.APP_DEBUG=1 to enable verbose logs.
const APP_DEBUG = !!process.env.APP_DEBUG;
if (!APP_DEBUG) {
  try {
    console.log = function() {};
    console.info = function() {};
    console.warn = function() {};
  } catch (e) {}
}

// Function to read Excel file with original format preservation
function safeCellToString(value) {
  if (value === undefined || value === null) return '';
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return String(value);
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'object') {
    if (value.t !== undefined && value.v !== undefined) {
      return String(value.t || value.v).trim();
    }
    return String(value).trim();
  }
  return String(value).trim();
}

async function readExcelFile(filePath) {
  try {
    const buffer = fs.readFileSync(filePath);
    const workbook = XLSX.read(buffer, { type: 'buffer', raw: false });
    const firstSheet = workbook.Sheets[workbook.SheetNames[0]];

    const range = XLSX.utils.decode_range(firstSheet['!ref']);
    const data = [];
    const headers = [];

    for (let C = range.s.c; C <= range.e.c; ++C) {
      const cell = firstSheet[XLSX.utils.encode_cell({ r: 0, c: C })];
      headers[C] = safeCellToString(cell?.v);
    }
    data.push(headers);

    for (let R = range.s.r + 1; R <= range.e.r; ++R) {
      const row = [];
      for (let C = range.s.c; C <= range.e.c; ++C) {
        const cell = firstSheet[XLSX.utils.encode_cell({ r: R, c: C })];
        row[C] = safeCellToString(cell?.v);
      }
      if (row.some((cell) => cell !== '' && cell !== undefined)) {
        data.push(row);
      }
    }

    return data;
  } catch (error) {
    console.error('Error reading Excel file:', error);
    throw error;
  }
}

// Function to write Excel file with proper handling of existing data
async function writeExcelFile(filePath, newData) {
  try {
    let existingData = [];
    // Try to read existing file
    if (fs.existsSync(filePath)) {
      try {
        const workbook = XLSX.readFile(filePath);
        const sheet = workbook.Sheets[workbook.SheetNames[0]];
        existingData = XLSX.utils.sheet_to_json(sheet);
      } catch (err) {
        console.log('Could not read existing file, starting fresh');
      }
    }

    // Combine existing and new data, removing duplicates
    const combinedData = [...newData, ...existingData].filter((item, index, self) =>
      index === self.findIndex((t) => {
        try {
          const keyA = (t['Generated code 1'] || t['Scanned Code'] || '').toString();
          const keyB = (item['Generated code 1'] || item['Scanned Code'] || '').toString();
          return t['Time'] === item['Time'] && keyA === keyB;
        } catch (e) {
          try {
            const keyA = (t['Generated code 1'] || t['Scanned Code'] || '').toString();
            const keyB = (item['Generated code 1'] || item['Scanned Code'] || '').toString();
            return t['Time'] === item['Time'] && keyA === keyB;
          } catch (ee) {
            return t['Time'] === item['Time'] && t['Scanned Code'] === item['Scanned Code'];
          }
        }
      })
    );

    // Create and format worksheet
    const ws = XLSX.utils.json_to_sheet(combinedData);
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Scan Logs');

    // Auto-size columns
    const colWidths = {};
    const columnNames = Object.keys(combinedData[0] || {});
    columnNames.forEach(col => {
      const allValues = combinedData.map(row => String(row[col] || ''));
      allValues.push(col); // Include header in width calculation
      colWidths[col] = Math.max(...allValues.map(v => v.length)) + 2;
    });
    ws['!cols'] = columnNames.map(col => ({ wch: colWidths[col] }));

    // Write file
    XLSX.writeFile(wb, filePath);
    return { success: true, count: combinedData.length };
  } catch (error) {
    console.error('Error writing Excel file:', error);
    throw error;
  }
}

// Register IPC handlers immediately on app start
// Use project working directory when running unpackaged so master.xlsx
// in the project root is picked up (same behaviour as before).
const rootPath = app.isPackaged
  ? path.dirname(app.getPath('exe'))
  : process.cwd();

// Web server service (local LAN HTTPS server)
const WebServerService = require('./main/services/WebServerService');
let webServerService = null;

// Register web-server IPC handlers early so renderer can call them before app.ready
ipcMain.handle('start-web-server', async (event, displayAddress) => {
  try {
    if (displayAddress && webServerService && typeof webServerService.setDisplayAddress === 'function') {
      webServerService.setDisplayAddress(displayAddress);
    }
    if (!webServerService) return { success: false, error: 'Service not ready' };
    return await webServerService.startServer();
  } catch (err) {
    return { success: false, error: err.message };
  }
});

ipcMain.handle('stop-web-server', async () => {
  try {
    if (!webServerService) return { success: false, error: 'Service not ready' };
    return await webServerService.stopServer();
  } catch (err) { return { success: false, error: err.message }; }
});

ipcMain.handle('get-server-status', async () => {
  try { if (!webServerService) return { success: true, isRunning: false }; return await webServerService.getServerStatus(); } catch (err) { return { success: false, error: err.message }; }
});

ipcMain.handle('regenerate-web-server-tls', async () => {
  try { if (!webServerService) return { success: false, error: 'Service not ready' }; return await webServerService.regenerateTLS(); } catch (err) { return { success: false, error: err.message }; }
});

ipcMain.handle('set-web-server-tls', (event, tlsOptions) => {
  try { if (!webServerService) return { success: false, error: 'Service not ready' }; return webServerService.setTLSOptions(tlsOptions || {}); } catch (err) { return { success: false, error: err.message }; }
});

ipcMain.handle('get-local-ips', () => {
  try { if (!webServerService) return { success: false, error: 'Service not ready' }; return { success: true, ips: webServerService.getLocalIPAddresses() }; } catch (err) { return { success: false, error: err.message }; }
});

ipcMain.handle('get-ca-cert', () => {
  try { if (!webServerService) return { success: false, error: 'Service not ready' }; return webServerService.getCAcert(); } catch (err) { return { success: false, error: err.message }; }
});

// Persist auto-start setting for web server
ipcMain.handle('set-web-server-autostart', (event, flag) => {
  try {
    if (!webServerService) return { success: false, error: 'Service not ready' };
    return webServerService.setAutoStart(!!flag);
  } catch (err) { return { success: false, error: err.message }; }
});

ipcMain.handle('get-web-server-config', () => {
  try {
    if (!webServerService) return { success: false, error: 'Service not ready' };
    return webServerService.getConfig();
  } catch (err) { return { success: false, error: err.message }; }
});

const defaultPrintTestConfig = {
  printerName: '',
  mediaWidthMm: 58.42,
  mediaHeightMm: 14.986,
  borderMarginMm: 0.75,
  autoFit: false,
  moduleDots: 3,
  barHeightPercent: 100,
  offsetXmm: 0,
  offsetYmm: 0,
  applyDarkness: false,
  darknessLevel: 9
};

function getPrintTestConfigPath() {
  return path.join(app.getPath('userData'), 'print-test-settings.json');
}

function readPrintTestConfig() {
  try {
    const saved = JSON.parse(fs.readFileSync(getPrintTestConfigPath(), 'utf8'));
    const config = { ...defaultPrintTestConfig, ...saved };
    if (saved.mediaFitVersion !== 4) {
      config.autoFit = false;
      config.moduleDots = 4;
    }
    return config;
  } catch (error) {
    if (error.code === 'ENOENT') return { ...defaultPrintTestConfig };
    throw error;
  }
}

ipcMain.handle('get-print-test-config', async (event) => {
  try {
    const [config, printers] = await Promise.all([
      Promise.resolve(readPrintTestConfig()),
      event.sender.getPrintersAsync()
    ]);
    return {
      success: true,
      config,
      printers: printers.map(({ name, isDefault }) => ({ name, isDefault }))
    };
  } catch (error) {
    console.error('Unable to load print test configuration:', error);
    return { success: false, error: error.message };
  }
});

async function getPrinterMedia(printerName, webContents, mediaOverride) {
  if (process.platform !== 'win32') {
    throw new Error('Active printer media detection is supported only on Windows');
  }
  const printers = await webContents.getPrintersAsync();
  const printer = printerName
    ? printers.find(item => item.name === printerName)
    : printers.find(item => item.isDefault);
  if (!printer) throw new Error(printerName
    ? 'Selected printer is not currently installed'
    : 'Windows has no default printer selected');

  const escapedName = printer.name.replace(/'/g, "''");
  const script = [
    "$ErrorActionPreference='Stop'",
    'Add-Type -AssemblyName System.Drawing',
    `$printerName='${escapedName}'`,
    '$document=[System.Drawing.Printing.PrintDocument]::new()',
    '$document.PrinterSettings.PrinterName=$printerName',
    'if (-not $document.PrinterSettings.IsValid) { throw "Printer is unavailable" }',
    '$paper=$document.DefaultPageSettings.PaperSize',
    '$resolution=$document.DefaultPageSettings.PrinterResolution',
    'if ($paper.Width -le 0 -or $paper.Height -le 0) { throw "Driver did not report a default paper size" }',
    'if ($resolution.X -le 0 -or $resolution.Y -le 0) { throw "Driver did not report a usable print resolution" }',
    '[pscustomobject]@{ printerName=$printerName; paperName=$paper.PaperName; widthHundredthInch=$paper.Width; heightHundredthInch=$paper.Height; dpiX=$resolution.X; dpiY=$resolution.Y } | ConvertTo-Json -Compress',
    '$document.Dispose()'
  ].join('; ');
  const { stdout } = await execFileAsync('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-Command', script
  ], { windowsHide: true, timeout: 15000, maxBuffer: 1024 * 1024 });
  const media = JSON.parse(stdout.trim());
  if (!Number.isFinite(media.widthHundredthInch) ||
      !Number.isFinite(media.heightHundredthInch) ||
      !Number.isFinite(media.dpiX) || !Number.isFinite(media.dpiY)) {
    throw new Error('Printer driver returned invalid default media information');
  }
  if (mediaOverride !== undefined) {
    const { widthMm, heightMm } = mediaOverride || {};
    if (!Number.isFinite(widthMm) || widthMm < 10 || widthMm > 104 ||
        !Number.isFinite(heightMm) || heightMm < 5 || heightMm > 300) {
      throw new Error('Custom label size must be 10–104 mm wide and 5–300 mm high');
    }
    media.detectedPaperName = media.paperName;
    media.detectedWidthHundredthInch = media.widthHundredthInch;
    media.detectedHeightHundredthInch = media.heightHundredthInch;
    media.widthHundredthInch = Math.round(widthMm / 0.254);
    media.heightHundredthInch = Math.round(heightMm / 0.254);
    media.paperName = 'App custom label';
    media.customMedia = true;
  }
  const widthDots = Math.round(media.widthHundredthInch * media.dpiX / 100);
  const heightDots = Math.round(media.heightHundredthInch * media.dpiY / 100);
  if (widthDots < 1 || heightDots < 1 || widthDots * heightDots > 40000000) {
    throw new Error('Printer default media is too large or invalid for safe barcode rendering');
  }
  return { ...media, isDefault: printer.isDefault };
}

ipcMain.handle('get-printer-media', async (event, printerName, mediaSettings) => {
  try {
    const config = readPrintTestConfig();
    const mediaOverride = mediaSettings || {
      widthMm: config.mediaWidthMm,
      heightMm: config.mediaHeightMm
    };
    return {
      success: true,
      media: await getPrinterMedia(printerName, event.sender, mediaOverride)
    };
  } catch (error) {
    console.error('Unable to detect printer media:', error);
    return { success: false, error: error.message };
  }
});

ipcMain.handle('save-print-test-config', async (event, config) => {
  try {
    if (!config || typeof config !== 'object') throw new Error('Invalid print configuration');
    const {
      printerName, mediaWidthMm, mediaHeightMm, borderMarginMm, autoFit, moduleDots, barHeightPercent, offsetXmm, offsetYmm,
      applyDarkness, darknessLevel
    } = config;
    if (typeof printerName !== 'string') throw new Error('Select a printer');
    if (!Number.isFinite(mediaWidthMm) || mediaWidthMm < 10 || mediaWidthMm > 104 ||
        !Number.isFinite(mediaHeightMm) || mediaHeightMm < 5 || mediaHeightMm > 300) {
      throw new Error('Custom label size must be 10–104 mm wide and 5–300 mm high');
    }
    if (!Number.isFinite(borderMarginMm) || borderMarginMm < 0.25 || borderMarginMm > 2) {
      throw new Error('Barcode border margin must be between 0.25 and 2 mm');
    }
    if (typeof autoFit !== 'boolean') throw new Error('Automatic fitting must be enabled or disabled');
    if (!Number.isFinite(moduleDots) || moduleDots < 3 || moduleDots > 5) {
      throw new Error('Barcode module width must be between 3 and 5 printer dots');
    }
    if (!Number.isFinite(barHeightPercent) || barHeightPercent < 50 || barHeightPercent > 100) {
      throw new Error('Barcode height must be between 50 and 100 percent');
    }
    if (!Number.isFinite(offsetXmm) || Math.abs(offsetXmm) > 1.5 ||
        !Number.isFinite(offsetYmm) || Math.abs(offsetYmm) > 1.5) {
      throw new Error('Position adjustment must be between -1.5 and 1.5 mm');
    }
    if (typeof applyDarkness !== 'boolean' ||
        !Number.isInteger(darknessLevel) || darknessLevel < 0 || darknessLevel > 15) {
      throw new Error('Darkness override must be disabled or a level from 0 to 15');
    }
    if (printerName) {
      const printers = await event.sender.getPrintersAsync();
      if (!printers.some(printer => printer.name === printerName)) {
        throw new Error('Selected printer is not currently installed');
      }
    }

    const saved = {
      printerName, mediaWidthMm, mediaHeightMm, borderMarginMm, autoFit, moduleDots, barHeightPercent, offsetXmm, offsetYmm,
      applyDarkness, darknessLevel
    };
    saved.mediaFitVersion = 4;
    fs.mkdirSync(path.dirname(getPrintTestConfigPath()), { recursive: true });
    fs.writeFileSync(getPrintTestConfigPath(), JSON.stringify(saved, null, 2), 'utf8');
    return { success: true, config: saved };
  } catch (error) {
    console.error('Unable to save print test configuration:', error);
    return { success: false, error: error.message };
  }
});

ipcMain.handle('open-printer-preferences', async (event, printerName) => {
  try {
    if (process.platform !== 'win32') throw new Error('Printer preferences are available only on Windows');
    if (typeof printerName !== 'string') throw new Error('Invalid printer selection');
    const media = await getPrinterMedia(printerName, event.sender);
    await execFileAsync('rundll32.exe', [
      'printui.dll,PrintUIEntry', '/e', '/n', media.printerName
    ]);
    return { success: true };
  } catch (error) {
    console.error('Unable to open printer preferences:', error);
    return { success: false, error: error.message };
  }
});

let printQueue = Promise.resolve();

// Keep print jobs sequential so multiple requests cannot overlap printer setup
// or submit pages out of order.
ipcMain.handle('print-barcode', (event, data) => {
  const queuedPrint = printQueue.then(() => printBarcode(data, event.sender));
  printQueue = queuedPrint.then(() => undefined, () => undefined);
  return queuedPrint;
});

// One print request is exactly one label page; the printer's gap sensor advances
// the stock to the next label between pages.
async function printBarcode(data, webContents) {
  try {
    if (!data || typeof data !== 'object') throw new Error('Invalid barcode print request');
    const savedConfig = readPrintTestConfig();
    const { barcode } = data;
    const printerName = data.printerName ?? savedConfig.printerName;
    const mediaWidthMm = data.mediaWidthMm ?? savedConfig.mediaWidthMm;
    const mediaHeightMm = data.mediaHeightMm ?? savedConfig.mediaHeightMm;
    const borderMarginMm = data.borderMarginMm ?? savedConfig.borderMarginMm;
    const autoFit = data.autoFit ?? savedConfig.autoFit;
    const moduleDots = data.moduleDots ?? savedConfig.moduleDots;
    const barHeightPercent = data.barHeightPercent ?? savedConfig.barHeightPercent;
    const offsetXmm = data.offsetXmm ?? savedConfig.offsetXmm;
    const offsetYmm = data.offsetYmm ?? savedConfig.offsetYmm;
    const applyDarkness = data.applyDarkness ?? savedConfig.applyDarkness;
    const darknessLevel = data.darknessLevel ?? savedConfig.darknessLevel;
    if (!Code128Encoder.isValidPayload(barcode)) {
      throw new Error('Barcode payload is invalid or has an invalid check digit');
    }
    const barcodePattern = Code128Encoder.encode(barcode);
    if (typeof autoFit !== 'boolean' ||
        typeof printerName !== 'string' ||
        !Number.isFinite(mediaWidthMm) || mediaWidthMm < 10 || mediaWidthMm > 104 ||
        !Number.isFinite(mediaHeightMm) || mediaHeightMm < 5 || mediaHeightMm > 300 ||
        !Number.isFinite(borderMarginMm) || borderMarginMm < 0.25 || borderMarginMm > 2 ||
        typeof applyDarkness !== 'boolean' ||
        !Number.isInteger(darknessLevel) || darknessLevel < 0 || darknessLevel > 15 ||
        !Number.isFinite(moduleDots) || moduleDots < 3 || moduleDots > 5 ||
        !Number.isFinite(barHeightPercent) || barHeightPercent < 50 || barHeightPercent > 100 ||
        !Number.isFinite(offsetXmm) || Math.abs(offsetXmm) > 1.5 ||
        !Number.isFinite(offsetYmm) || Math.abs(offsetYmm) > 1.5) {
      throw new Error('Invalid barcode print settings');
    }
    if (process.platform !== 'win32') {
      throw new Error('Direct barcode printing through the Windows printer driver is supported only on Windows');
    }

    const media = await getPrinterMedia(printerName, webContents, {
      widthMm: mediaWidthMm,
      heightMm: mediaHeightMm
    });
    const expectedMedia = [
      ['mediaPrinterName', media.printerName],
      ['mediaWidthHundredthInch', media.widthHundredthInch],
      ['mediaHeightHundredthInch', media.heightHundredthInch],
      ['mediaDpiX', media.dpiX],
      ['mediaDpiY', media.dpiY],
    ];
    if (expectedMedia.some(([key]) => data[key] !== undefined) &&
        expectedMedia.some(([key, expected]) => data[key] !== expected)) {
      throw new Error('Printer media or resolution changed. Refresh detected settings and try again.');
    }
    const scriptPath = app.isPackaged
      ? path.join(process.resourcesPath, 'scripts', 'tsc-print-calibration.ps1')
      : path.join(__dirname, 'scripts', 'tsc-print-calibration.ps1');
    if (!fs.existsSync(scriptPath)) throw new Error('The direct-print middleware script is missing');

    const powershellArgs = [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-PrinterName', media.printerName,
      '-Barcode', barcode,
      '-BarcodePattern', barcodePattern,
      '-ModuleDots', String(moduleDots),
      '-BorderMarginMm', String(borderMarginMm),
      '-BarHeightPercent', String(barHeightPercent),
      '-OffsetXmm', String(offsetXmm),
      '-OffsetYmm', String(offsetYmm),
      '-ExpectedWidthHundredthInch', String(media.widthHundredthInch),
      '-ExpectedHeightHundredthInch', String(media.heightHundredthInch),
      '-LabelWidthHundredthInch', String(media.widthHundredthInch),
      '-LabelHeightHundredthInch', String(media.heightHundredthInch),
      '-ExpectedDpiX', String(media.dpiX),
      '-ExpectedDpiY', String(media.dpiY),
      '-AllowOtherPrinter',
      '-Print',
    ];
    if (autoFit) powershellArgs.push('-AutoFit');
    if (applyDarkness) powershellArgs.push('-DarknessLevel', String(darknessLevel));
    const { stdout } = await execFileAsync('powershell.exe', powershellArgs, {
      windowsHide: true,
      timeout: 120000,
      maxBuffer: 1024 * 1024,
    });
    console.log('[print] middleware submitted barcode:', barcode, stdout.trim());
    return { success: true, barcode, message: stdout.trim() };

  } catch (error) {
    console.error('Print barcode error:', error);
    const details = error.stderr ? error.stderr.trim() : error.message;
    return { success: false, error: details };
  }
}

// Allow renderer to broadcast session updates (selected row / field info) to connected mobile clients
ipcMain.handle('broadcast-session-update', async (event, session) => {
  try {
    if (!webServerService) return { success: false, error: 'Service not ready' };
    return webServerService.broadcastSessionUpdate(session || {});
  } catch (err) { return { success: false, error: err.message }; }
});

// Handle reading master data
ipcMain.handle('read-master-data', async () => {
  // Only look for master.xlsx in the application/project root (previous behaviour)
  const masterFilePath = path.join(rootPath, 'master.xlsx');
  console.log('[IPC] read-master-data invoked. rootPath=', rootPath);
  console.log('[IPC] master path =', masterFilePath);

  try {
    if (!fs.existsSync(masterFilePath)) {
      console.error('[IPC] master.xlsx not found at', masterFilePath);
      dialog.showErrorBox(
        'File Not Found',
        'master.xlsx not found in the application root.\n\nPlease place master.xlsx in the project root and restart the app.'
      );
      return null;
    }

    console.log('[IPC] reading master file at', masterFilePath);
    return await readExcelFile(masterFilePath);
  } catch (error) {
    console.error('[IPC] error reading master file:', error);
    dialog.showErrorBox(
      'Error Reading Master Data',
      `Could not read master.xlsx:\n${error.message}\n\nPlease ensure the file is not open in Excel.`
    );
    return null;
  }
});

// Handle writing logs (for manual export)
ipcMain.handle('write-logs', async (event, data) => {
  const today = new Date().toISOString().split('T')[0];
  // Use the same history-<date>.xlsx filename pattern as real-time saves
  const logFilePath = path.join(rootPath, `history-${today}.xlsx`);
  try {
    const result = await writeExcelFile(logFilePath, data);
    return { success: true, filePath: logFilePath, ...result };
  } catch (error) {
    dialog.showErrorBox(
      'Error Saving Logs',
      `Could not save logs:\n${error.message}\n\nPlease ensure the file is not open in Excel and you have write permissions.`
    );
    return { success: false, error: error.message };
  }
});

// Handle reading logs for a specific date
ipcMain.handle('read-logs', async (event, data) => {
  const { date } = data;
  const logFilePath = path.join(rootPath, `history-${date}.xlsx`);

  console.log('read-logs called for date:', date);
  console.log('Log file path:', logFilePath);

  try {
    if (!fs.existsSync(logFilePath)) {
      console.log('Log file does not exist for date:', date);
      return [];
    }

    console.log('Reading log file...');
    const workbook = XLSX.readFile(logFilePath);
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    const logsData = XLSX.utils.sheet_to_json(sheet);

    console.log('Loaded logs data:', logsData.length, 'entries');
    return logsData;
  } catch (error) {
    console.error('Error reading logs file:', error);
    return [];
  }
});

// Handle writing single log entry in real-time
ipcMain.handle('write-single-log', async (event, data) => {
  const { log, date } = data;
  const logFilePath = path.join(rootPath, `history-${date}.xlsx`);

  console.log('write-single-log called for date:', date);
  console.log('Log file path:', logFilePath);
  console.log('Log entry:', log);

  try {
    let existingData = [];

    // Try to read existing file
    if (fs.existsSync(logFilePath)) {
      try {
        console.log('Reading existing log file...');
        const workbook = XLSX.readFile(logFilePath);
        const sheet = workbook.Sheets[workbook.SheetNames[0]];
        existingData = XLSX.utils.sheet_to_json(sheet);
        console.log('Existing data loaded:', existingData.length, 'entries');
      } catch (err) {
        console.log('Could not read existing file, starting fresh:', err.message);
      }
    } else {
      console.log('No existing file found, creating new one');
    }

    // Add new log entry at the beginning (newest first)
    const combinedData = [log, ...existingData];
    console.log('Total entries after adding new log:', combinedData.length);

    // Create and format worksheet
    const ws = XLSX.utils.json_to_sheet(combinedData);
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Scan Logs');

    // Auto-size columns
    const colWidths = {};
    const columnNames = Object.keys(log);
    columnNames.forEach(col => {
      const allValues = combinedData.map(row => String(row[col] || ''));
      allValues.push(col); // Include header in width calculation
      colWidths[col] = Math.max(...allValues.map(v => v.length)) + 2;
    });
    ws['!cols'] = columnNames.map(col => ({ wch: colWidths[col] }));

    // Write file
    XLSX.writeFile(wb, logFilePath);
    console.log('Log file written successfully');

    return { success: true, filePath: logFilePath, count: combinedData.length };
  } catch (error) {
    console.error('Error writing single log:', error);
    // Don't show error dialog for real-time saves to avoid interrupting workflow
    return { success: false, error: error.message };
  }
});

function createWindow() {
  // Create the browser window.
  const mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      enableRemoteModule: true
    }
  });

  // Keep index.html as the main application page.
  mainWindow.loadFile('index.html');

  // Maximize the window
  mainWindow.maximize();

  // Open DevTools in development
  // mainWindow.webContents.openDevTools();
}

// Accept self-signed certs for the local web server (development convenience)
// This prevents ERR_CERT_AUTHORITY_INVALID when loading the app's mobile page
app.on('certificate-error', (event, webContents, url, error, certificate, callback) => {
  try {
    const parsed = new URL(url);
    const host = parsed.hostname;
    const port = parsed.port || (parsed.protocol === 'https:' ? '443' : '80');

    // Build a dynamic allowlist: localhost + any IPs/hosts returned by webServerService
    const allowList = new Set(['localhost', '127.0.0.1', '::1']);
    if (webServerService) {
      try {
        if (webServerService.mobileUrl) {
          const m = new URL(webServerService.mobileUrl);
          if (m.hostname) allowList.add(m.hostname);
          if (m.port) allowList.add(String(m.port));
        }
      } catch (e) {}

      try {
        const ips = webServerService.getLocalIPAddresses();
        (ips || []).forEach(i => { if (i && i.address) allowList.add(i.address); });
      } catch (e) {}

      try {
        if (webServerService.displayAddress) allowList.add(webServerService.displayAddress);
      } catch (e) {}
    }

    // If the request host is in the allowlist and the port matches our web server
    if ((allowList.has(host) || allowList.has(`${host}`)) &&
        (!webServerService || !webServerService.port || String(port) === String(webServerService.port))) {
      event.preventDefault();
      try { callback(true); } catch (e) {}
      return;
    }
  } catch (e) {
    // ignore parsing errors
  }

  try { callback(false); } catch (e) {}
});

// Handle app exit
ipcMain.on('close-app', () => {
  app.quit();
});

// When Electron is ready
app.whenReady().then(() => {
  createWindow();

  // Instantiate WebServerService with minimal dependencies (nulls are acceptable)
  try {
    webServerService = new WebServerService(null, null, null, null);
  } catch (e) {
    console.error('Failed to initialize WebServerService:', e && e.message);
  }

  // If the service was configured to auto-start, start it now (best-effort)
  (async () => {
    try {
      if (webServerService && webServerService.autoStart) {
        try { await webServerService.startServer(); } catch (e) { console.warn('Auto-start server failed:', e && e.message); }
      }
    } catch (e) {}
  })();

  // webServerService is instantiated above; nothing else to do here

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});
