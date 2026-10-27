package anker

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const (
	fxAcknowledgement = "ff090e0003010f0a0b00a1013460"
	fxVersionInfo     = "ff093e0003010f0830a10600312e302e30a20800322e312e312e36a306004132333435a40a0041323334355f6d6375a50c0041323334355f657370333214"
)

func jsonData(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func expectFrame(t *testing.T, payload, want []byte) {
	t.Helper()
	got, err := DecodeCloudPayload(payload)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("got %x, %v", got, err)
	}
}

func expectPayloadError(t *testing.T, payload []byte, want PayloadError) {
	t.Helper()
	if _, err := DecodeCloudPayload(payload); !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
}

func TestPayloadReturnsRawFF09Unchanged(t *testing.T) {
	ack := mustHex(t, fxAcknowledgement)
	expectFrame(t, ack, ack)
}

func TestPayloadDecodesOuterPayloadStringContainingNestedJSON(t *testing.T) {
	ack := mustHex(t, fxAcknowledgement)
	nested := jsonData(t, map[string]any{"data": base64.StdEncoding.EncodeToString(ack)})
	expectFrame(t, jsonData(t, map[string]any{"payload": string(nested)}), ack)
}

func TestPayloadFindsBase64FrameUnderArbitrarilyNestedDataOrPayloadKeys(t *testing.T) {
	ack := mustHex(t, fxAcknowledgement)
	expectFrame(t, jsonData(t, map[string]any{
		"metadata": map[string]any{"ignored": true},
		"items":    []any{map[string]any{"wrapper": map[string]any{"payload": base64.StdEncoding.EncodeToString(ack)}}},
	}), ack)
}

func TestPayloadAllowsDuplicateCopiesOfTheSameFrame(t *testing.T) {
	ack := mustHex(t, fxAcknowledgement)
	enc := base64.StdEncoding.EncodeToString(ack)
	expectFrame(t, jsonData(t, map[string]any{"data": enc, "nested": []any{map[string]any{"payload": enc}}}), ack)
}

func TestPayloadValidFrameWinsOverUnrelatedInvalidDataSibling(t *testing.T) {
	ack := mustHex(t, fxAcknowledgement)
	expectFrame(t, jsonData(t, map[string]any{
		"data":    "ordinary-envelope-metadata",
		"message": map[string]any{"payload": base64.StdEncoding.EncodeToString(ack)},
	}), ack)
}

func TestPayloadRejectsAmbiguousDistinctFrames(t *testing.T) {
	expectPayloadError(t, jsonData(t, map[string]any{
		"data":   base64.StdEncoding.EncodeToString(mustHex(t, fxAcknowledgement)),
		"nested": map[string]any{"payload": base64.StdEncoding.EncodeToString(mustHex(t, fxVersionInfo))},
	}), PayloadAmbiguousFrames)
}

func TestPayloadRejectsBadCandidates(t *testing.T) {
	expectPayloadError(t, jsonData(t, map[string]any{"data": "%%%not-base64%%%"}), PayloadInvalidBase64)
	expectPayloadError(t, jsonData(t, map[string]any{"payload": base64.StdEncoding.EncodeToString([]byte("ordinary text"))}), PayloadNonFF09)
	expectPayloadError(t, []byte{1, 2, 3}, PayloadNonFF09)
	corrupt := mustHex(t, fxAcknowledgement)
	corrupt[len(corrupt)-1] ^= 1
	expectPayloadError(t, corrupt, PayloadInvalidFrame)
}

func TestPayloadRejectsMalformedOuterAndNestedJSON(t *testing.T) {
	expectPayloadError(t, []byte(`{"data": `), PayloadMalformedJSON)
	expectPayloadError(t, jsonData(t, map[string]any{"payload": "  {not-json}"}), PayloadMalformedJSON)
}

func TestPayloadRejectsEmptyPayloadAndJSONWithoutCandidate(t *testing.T) {
	expectPayloadError(t, nil, PayloadEmpty)
	expectPayloadError(t, jsonData(t, map[string]any{"message": map[string]any{"value": "ignored"}}), PayloadFrameNotFound)
}

func TestPayloadRejectsOversizedInputAndCandidateBeforeDecoding(t *testing.T) {
	expectPayloadError(t, bytes.Repeat([]byte{' '}, PayloadMaximumInputBytes+1), PayloadInputTooLarge)
	expectPayloadError(t, jsonData(t, map[string]any{"data": strings.Repeat("A", PayloadMaximumBase64Characters+1)}), PayloadCandidateTooLarge)
}

func TestPayloadRejectsJSONBeyondMaximumDepth(t *testing.T) {
	var object any = map[string]any{"data": base64.StdEncoding.EncodeToString(mustHex(t, fxAcknowledgement))}
	for range PayloadMaximumJSONDepth + 1 {
		object = map[string]any{"nested": object}
	}
	expectPayloadError(t, jsonData(t, object), PayloadMaximumDepthExceeded)
}
