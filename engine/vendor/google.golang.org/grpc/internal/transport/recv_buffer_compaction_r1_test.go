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

package transport

import (
	"testing"

	imem "google.golang.org/grpc/internal/mem"
	"google.golang.org/grpc/mem"
)

func TestRatio1RecvBufferCompactsFragmentedBacklog(t *testing.T) {
	pool := mem.DefaultBufferPool()
	var buffer recvBuffer
	buffer.init(pool)

	messageCount := imem.BufferPoolingThreshold + 2
	for i := 0; i < messageCount; i++ {
		buffer.put(recvMsg{buffer: mem.Copy([]byte{0x0a}, pool)})
	}

	if got, want := len(buffer.backlog), 1; got != want {
		t.Fatalf("backlog length after compaction = %d, want %d", got, want)
	}
	if got := buffer.backlog[0].buffer.Len(); got != messageCount-1 {
		t.Fatalf("compacted payload length = %d, want %d", got, messageCount-1)
	}
	if buffer.uncompactedSuffixLen != 0 || buffer.uncompactedBytes != 0 {
		t.Fatalf(
			"uncompacted counters after compaction = (%d, %d), want (0, 0)",
			buffer.uncompactedSuffixLen,
			buffer.uncompactedBytes,
		)
	}

	(<-buffer.c).buffer.Free()
	for _, message := range buffer.backlog {
		message.buffer.Free()
	}
}
