extension Dictionary {
    /// The value for a key the caller guarantees is present.
    ///
    /// Layout and routing code builds lookup tables (node indices, ranks, lanes) from the same collections it later
    /// queries, so a missing key is a programming error rather than a recoverable condition. This traps exactly as a
    /// force unwrap would, but names the missing key and the call site.
    @inline(__always)
    subscript(
        required key: Key,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Value {
        guard let value = self[key] else {
            preconditionFailure("Missing required dictionary key \(key)", file: file, line: line)
        }
        return value
    }
}
