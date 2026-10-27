package winble

import (
	"context"
	"errors"
	"strings"
	"testing"

	"charker/internal/transport"
)

func TestIsRepeatedInit(t *testing.T) {
	yes := []error{
		errors.New("函数不正确。"),
		errors.New("The function is incorrect."),
		errors.New("RPC_E_CHANGED_MODE: already initialized"),
	}
	for _, err := range yes {
		if !isRepeatedInit(err) {
			t.Errorf("isRepeatedInit(%q) = false, want true", err)
		}
	}
	no := []error{nil, errors.New("The radio is not available"), errors.New("device with the given address was not found")}
	for _, err := range no {
		if isRepeatedInit(err) {
			t.Errorf("isRepeatedInit(%q) = true, want false", err)
		}
	}
}

func TestBackendErrorFragments(t *testing.T) {
	if !isDeviceNotFound(errors.New("bluetooth: device with the given address was not found")) {
		t.Error("device-not-found text not recognised")
	}
	if !isNoScan(errors.New("bluetooth: there is no scan in progress")) {
		t.Error("no-scan text not recognised")
	}
	if !isScanInProgress(errors.New("bluetooth: a scan is already in progress")) {
		t.Error("scan-in-progress text not recognised")
	}
	if !isConnectTimeout(errors.New("bluetooth: timeout on Connect")) {
		t.Error("connect-timeout text not recognised")
	}
}

func TestIsRadioUnavailable(t *testing.T) {
	yes := []error{
		errors.New("The radio is not available"),
		errors.New("Bluetooth radio is off"),
		errors.New("Element not found."),
		errors.New("HRESULT 0x80070490"),
		errors.New("class not registered"),
		errors.New("0x80040154"),
		errors.New("no bluetooth device found"),
	}
	for _, err := range yes {
		if !isRadioUnavailable(err) {
			t.Errorf("isRadioUnavailable(%q) = false, want true", err)
		}
	}
	no := []error{nil, errors.New("device with the given address was not found"), errors.New("write failed")}
	for _, err := range no {
		if isRadioUnavailable(err) {
			t.Errorf("isRadioUnavailable(%q) = true, want false", err)
		}
	}
}

func TestMapScanError(t *testing.T) {
	if err := mapScanError(nil); err != nil {
		t.Fatalf("mapScanError(nil) = %v, want nil", err)
	}
	if err := mapScanError(errors.New("bluetooth: a scan is already in progress")); err != nil {
		t.Fatalf("mapScanError(already scanning) = %v, want nil", err)
	}
	for _, in := range []string{"The radio is not available", "Element not found.", "watcher activation failed"} {
		err := mapScanError(errors.New(in))
		if !errors.Is(err, transport.ErrUnsupported) {
			t.Errorf("mapScanError(%q) = %v, want transport.ErrUnsupported", in, err)
		}
		if !strings.Contains(err.Error(), in) {
			t.Errorf("mapScanError(%q) = %v, want the backend detail in the message", in, err)
		}
	}
}

func TestMapConnectError(t *testing.T) {
	err := mapConnectError(errors.New("device with the given address was not found"))
	if !errors.Is(err, transport.ErrNotFound) {
		t.Errorf("not-found connect error = %v, want transport.ErrNotFound", err)
	}
	err = mapConnectError(errors.New("bluetooth: timeout on Connect"))
	if !errors.Is(err, transport.ErrTimeout) {
		t.Errorf("timeout connect error = %v, want transport.ErrTimeout", err)
	}
	err = mapConnectError(errors.New("The radio is not available"))
	if !errors.Is(err, transport.ErrUnsupported) {
		t.Errorf("radio-off connect error = %v, want transport.ErrUnsupported", err)
	}
	err = mapConnectError(errors.New("some other failure"))
	if errors.Is(err, transport.ErrNotFound) || errors.Is(err, transport.ErrTimeout) || errors.Is(err, transport.ErrUnsupported) {
		t.Errorf("generic connect error = %v, want no sentinel", err)
	}
	if err == nil {
		t.Fatal("mapConnectError(other) = nil")
	}
}

func TestMapGATTError(t *testing.T) {
	err := mapGATTError("discover services", errors.New("bluetooth: service not found"), true)
	if !errors.Is(err, transport.ErrNotFound) {
		t.Errorf("missing service error = %v, want transport.ErrNotFound", err)
	}
	err = mapGATTError("discover characteristics", errors.New("bluetooth: characteristic not found"), true)
	if !errors.Is(err, transport.ErrNotFound) {
		t.Errorf("missing characteristic error = %v, want transport.ErrNotFound", err)
	}
	err = mapGATTError("enable notifications", errors.New("Access is denied."), false)
	if !strings.Contains(err.Error(), "pairing") {
		t.Errorf("access-denied error = %v, want a pairing hint", err)
	}
	err = mapGATTError("discover services", errors.New("some other failure"), false)
	if err == nil || !strings.Contains(err.Error(), "discover services") {
		t.Errorf("generic GATT error = %v, want the step in the message", err)
	}
	if mapGATTError("x", nil, false) != nil {
		t.Error("mapGATTError(nil) != nil")
	}
}

func TestMapWriteError(t *testing.T) {
	if err := mapWriteError(20, nil); err != nil {
		t.Fatalf("mapWriteError(nil) = %v, want nil", err)
	}
	err := mapWriteError(193, errors.New("bluetooth: write failed"))
	if err == nil || !strings.Contains(err.Error(), "193 B") {
		t.Errorf("mapWriteError = %v, want the frame size in the message", err)
	}
	err = mapWriteError(20, errors.New("bluetooth: device is not connected"))
	if !errors.Is(err, transport.ErrNotConnected) {
		t.Errorf("not-connected write error = %v, want transport.ErrNotConnected", err)
	}
}

func TestErrFrameTooLong(t *testing.T) {
	if !strings.Contains(ErrFrameTooLong.Error(), "too long") {
		t.Errorf("ErrFrameTooLong = %v", ErrFrameTooLong)
	}
	if maxGATTValue != 512 {
		t.Errorf("maxGATTValue = %d, want 512 (GATT attribute value maximum)", maxGATTValue)
	}
}

func TestAbsInt(t *testing.T) {
	for _, tc := range []struct{ in, want int }{{0, 0}, {5, 5}, {-5, 5}, {-80, 80}} {
		if got := absInt(tc.in); got != tc.want {
			t.Errorf("absInt(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// TestTransportErrorsAreNotContextErrors keeps the transport's vocabulary
// separate from context.Canceled/DeadlineExceeded: the session maps them
// differently.
func TestTransportErrorsAreNotContextErrors(t *testing.T) {
	if errors.Is(transport.ErrTimeout, context.DeadlineExceeded) {
		t.Error("transport.ErrTimeout is context.DeadlineExceeded")
	}
}
