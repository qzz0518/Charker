package winble

import (
	"errors"
	"fmt"
	"strings"

	"charker/internal/transport"
)

// ErrFrameTooLong reports an application frame that cannot be sent in one GATT
// write. GATT attribute values are at most 512 octets (Bluetooth Core spec
// 3.2.9); A2687 frames are at most ~193 B, so this only fires on a protocol bug
// or on a caller that is not sending frames.
var ErrFrameTooLong = errors.New("winble: frame too long for one GATT write")

// maxGATTValue is the longest attribute value GATT can carry in one write.
const maxGATTValue = 512

// Error fragments of the WinRT backend and go-ole (tinygo.org/x/bluetooth on
// Windows). They are matched by text because neither exposes a typed error:
// errors from adapter.Connect are plain fmt.Errorf strings and the repeated
// RoInitialize error is a localised Win32 message ("The function is incorrect"
// / "函数不正确。").
const (
	errTextDeviceNotFound = "device with the given address was not found"
	errTextNoScan         = "there is no scan in progress"
	errTextScanning       = "a scan is already in progress"
	errTextConnectTimeout = "timeout on Connect"
)

// isDeviceNotFound reports the backend error for a MAC that is neither paired
// nor in the system scan cache (BluetoothLEDevice.FromBluetoothAddressAsync
// returned null). Recoverable by scanning; not fatal.
func isDeviceNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), errTextDeviceNotFound)
}

// isNoScan reports StopScan on an idle adapter, which is a no-op for us.
func isNoScan(err error) bool {
	return err != nil && strings.Contains(err.Error(), errTextNoScan)
}

// isScanInProgress reports a second Scan while one is running.
func isScanInProgress(err error) bool {
	return err != nil && strings.Contains(err.Error(), errTextScanning)
}

// isConnectTimeout reports the backend giving up on adapter.Connect.
func isConnectTimeout(err error) bool {
	return err != nil && strings.Contains(err.Error(), errTextConnectTimeout)
}

// isRepeatedInit reports go-ole's error for calling RoInitialize on a thread
// that is already initialised (S_FALSE). The message is localised, so both the
// English and the Simplified Chinese texts are recognised. A second transport
// (or a caller that enabled the adapter itself) must not be told Bluetooth is
// unavailable because of it.
func isRepeatedInit(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "incorrect") || strings.Contains(err.Error(), "不正确") ||
		strings.Contains(msg, "already initialized") || strings.Contains(msg, "already initialised")
}

// isRadioUnavailable reports a WinRT activation error meaning BLE cannot be
// used: radio off or in airplane mode, no adapter, driver not functioning, or
// the Bluetooth class not registered. Scan is the only place WinRT reveals
// this (Enable only calls RoInitialize and succeeds without a radio).
func isRadioUnavailable(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "radio") &&
		(strings.Contains(msg, "not available") || strings.Contains(msg, "unavailable") ||
			strings.Contains(msg, "off") || strings.Contains(msg, "disabled")):
		return true
	case strings.Contains(msg, "element not found"), strings.Contains(msg, "0x80070490"):
		return true
	case strings.Contains(msg, "class not registered"), strings.Contains(msg, "0x80040154"):
		return true
	case strings.Contains(msg, "device not found"), strings.Contains(msg, "no bluetooth"):
		return true
	}
	return false
}

// mapScanError turns a backend scan error into the transport's vocabulary.
// It returns nil for a harmless "already scanning" (idempotent Scan) and wraps
// transport.ErrUnsupported when Bluetooth itself is unavailable, so the session
// can show the "turn Bluetooth on" state instead of a generic failure.
func mapScanError(err error) error {
	switch {
	case err == nil:
		return nil
	case isScanInProgress(err), isNoScan(err):
		return nil
	case isRadioUnavailable(err):
		return fmt.Errorf("winble: Bluetooth is unavailable (radio off, no adapter, or a driver error): %w: %v",
			transport.ErrUnsupported, err)
	default:
		return fmt.Errorf("winble: scan failed: %w: %v", transport.ErrUnsupported, err)
	}
}

// mapConnectError turns a backend connect error into the transport's
// vocabulary. A not-found address is recoverable (the charger is out of range,
// held by another client, or the MAC rotated), so it maps to ErrNotFound rather
// than to a fatal error.
func mapConnectError(err error) error {
	switch {
	case err == nil:
		return nil
	case isConnectTimeout(err):
		return fmt.Errorf("winble: connect timed out: %w: %v", transport.ErrTimeout, err)
	case isDeviceNotFound(err):
		return fmt.Errorf("winble: charger did not answer (out of range, held by another app, or address rotated): %w: %v",
			transport.ErrNotFound, err)
	case isRadioUnavailable(err):
		return fmt.Errorf("winble: Bluetooth is unavailable: %w: %v", transport.ErrUnsupported, err)
	default:
		return fmt.Errorf("winble: connect failed: %v", err)
	}
}

// mapGATTError turns a service/characteristic discovery or subscribe error into
// the transport's vocabulary. missing says the backend answered
// ErrServiceNotFound/ErrCharacteristicNotFound, i.e. the device is not an
// A2687 (or a different firmware profile).
func mapGATTError(step string, err error, missing bool) error {
	if err == nil {
		return nil
	}
	msg := strings.ToLower(err.Error())
	switch {
	case missing:
		return fmt.Errorf("winble: %s: device does not expose the A2687 service/characteristics: %w: %v",
			step, transport.ErrNotFound, err)
	case strings.Contains(msg, "access denied") || strings.Contains(msg, "access is denied"):
		return fmt.Errorf("winble: %s: Windows denied access (the charger may require pairing): %v", step, err)
	default:
		return fmt.Errorf("winble: %s: %v", step, err)
	}
}

// mapWriteError turns a backend write error into a message with the frame size
// and the error class. Windows does not project WriteValueWithResultAsync, so a
// refused write has no ATT error code; callers must not infer
// success from a nil error alone either, the A2687 reply machinery decides.
func mapWriteError(n int, err error) error {
	if err == nil {
		return nil
	}
	if strings.Contains(strings.ToLower(err.Error()), "not connected") {
		return fmt.Errorf("winble: write %d B: %w: %v", n, transport.ErrNotConnected, err)
	}
	return fmt.Errorf("winble: write %d B failed: %v", n, err)
}

// absInt returns the absolute value of v, for RSSI-jitter comparisons.
func absInt(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
