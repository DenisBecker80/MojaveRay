package device

// Compatibility shims for Go 1.20. Keep protocol logic in the upstream engine.
func maxCompat[T ~int | ~int64](a, b T) T {
	if a > b {
		return a
	}
	return b
}

func zeroBytes(buf []byte) {
	for i := range buf {
		buf[i] = 0
	}
}

// Preserve the slice length and existing contents; only grow its capacity.
func growBytes(buf []byte, n int) []byte {
	if n < 0 {
		panic("cannot be negative")
	}
	if n <= cap(buf)-len(buf) {
		return buf
	}
	grown := make([]byte, len(buf), len(buf)+n)
	copy(grown, buf)
	return grown
}
