// ---------------------------------------------------------------------------
// The smallest program that does what Open CoDesign does with credentials.
//
// Open CoDesign stores its API keys with Electron's `safeStorage` (Chromium's
// OSCrypt): it calls `isEncryptionAvailable()` and, when that is true,
// `encryptString()`/`decryptString()` on a TOML/JSON blob in its config
// directory. When the OS keychain is unusable it refuses with
//   CodesignError: OS keychain (secure storage) is not available.
// so "the app cannot store keys" is exactly "this probe says available=false".
//
// Run it with the SAME Electron build and the SAME flags the app gets:
//   <electron-binary> <this-dir> --no-sandbox [--password-store=…]
// and it prints one machine-readable line, then exits.
// ---------------------------------------------------------------------------
const { app, safeStorage } = require('electron');

function line(fields) {
  console.log('PROBE ' + Object.entries(fields).map(([k, v]) => `${k}=${v}`).join(' '));
}

app.whenReady().then(() => {
  try {
    const available = safeStorage.isEncryptionAvailable();
    let backend = 'unknown';
    try {
      // Electron >= 15; 'basic' means Chromium's built-in obfuscation, which is
      // what --password-store=basic selects when no OS keychain is usable.
      backend = safeStorage.getSelectedStorageBackend();
    } catch (e) {
      backend = 'unavailable:' + e.message;
    }
    let roundtrip = false;
    let message = '';
    if (available) {
      try {
        const blob = safeStorage.encryptString('lbx-probe-value');
        roundtrip = safeStorage.decryptString(blob) === 'lbx-probe-value';
      } catch (e) {
        message = e.message;
      }
    }
    line({ available, backend, roundtrip, error: message || 'none' });
  } catch (e) {
    line({ available: 'exception', backend: 'exception', roundtrip: false, error: e.message });
  }
  app.exit(0);
});
