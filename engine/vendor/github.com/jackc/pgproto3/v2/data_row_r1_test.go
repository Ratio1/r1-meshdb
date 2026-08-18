// Copyright 2026 Ratio1
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package pgproto3

import (
	"bytes"
	"io"
	"testing"
)

func TestDataRowDecodeRejectsNegativeFieldLength(t *testing.T) {
	testCases := map[string][]byte{
		"negative two":  {0, 1, 0xff, 0xff, 0xff, 0xfe},
		"minimum int32": {0, 1, 0x80, 0, 0, 0},
	}
	for name, message := range testCases {
		t.Run(name, func(t *testing.T) {
			var row DataRow
			if err := row.Decode(message); err == nil {
				t.Fatal("expected a negative field length to be rejected")
			}
		})
	}
}

func TestDataRowDecodeRetainsNullField(t *testing.T) {
	var row DataRow
	if err := row.Decode([]byte{0, 1, 0xff, 0xff, 0xff, 0xff}); err != nil {
		t.Fatalf("valid null field was rejected: %v", err)
	}
	if len(row.Values) != 1 || row.Values[0] != nil {
		t.Fatalf("expected one null field, got %#v", row.Values)
	}
}

func TestFrontendReceiveRejectsNegativeDataRowFieldLength(t *testing.T) {
	frame := []byte{'D', 0, 0, 0, 10, 0, 1, 0xff, 0xff, 0xff, 0xfe}
	frontend := NewFrontend(NewChunkReader(bytes.NewReader(frame)), io.Discard)
	if _, err := frontend.Receive(); err == nil {
		t.Fatal("expected a malicious DataRow frame to be rejected")
	}
}
