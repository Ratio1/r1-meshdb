package pgproto3

import "testing"

func TestDataRowDecodeRejectsNegativeFieldLength(t *testing.T) {
	message := []byte{0, 1, 0x80, 0, 0, 0}
	var row DataRow
	if err := row.Decode(message); err == nil {
		t.Fatal("expected a negative field length to be rejected")
	}
}
