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

package thrift

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

func TestRatio1CompactProtocolRejectsOverlongVarint(t *testing.T) {
	payload := bytes.Repeat([]byte{0x80}, 11)
	transport := NewTMemoryBufferLen(len(payload))
	_, _ = transport.Write(payload)
	protocol := NewTCompactProtocol(transport)

	_, err := protocol.ReadI64(context.Background())
	var protocolErr TProtocolException
	if !errors.As(err, &protocolErr) || protocolErr.TypeId() != INVALID_DATA {
		t.Fatalf("overlong varint error = %v, want INVALID_DATA protocol error", err)
	}
	if got, want := transport.Len(), 1; got != want {
		t.Fatalf("unread payload bytes = %d, want %d", got, want)
	}
}

func TestRatio1CompactProtocolAcceptsValidTenByteVarint(t *testing.T) {
	payload := append(bytes.Repeat([]byte{0x80}, 9), 0x01)
	transport := NewTMemoryBufferLen(len(payload))
	_, _ = transport.Write(payload)
	protocol := NewTCompactProtocol(transport)

	if _, err := protocol.ReadI64(context.Background()); err != nil {
		t.Fatalf("valid ten-byte varint was rejected: %v", err)
	}
}
