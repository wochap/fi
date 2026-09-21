//! Destination for `tracing` output. Android discards a native process's stdout,
//! so there the log goes to logcat under the `fi_rust` tag; elsewhere it stays on
//! stdout.

#[cfg(not(target_os = "android"))]
pub(crate) fn make_writer() -> std::io::Stdout {
    std::io::stdout()
}

#[cfg(target_os = "android")]
pub(crate) fn make_writer() -> LogcatWriter {
    LogcatWriter::default()
}

#[cfg(target_os = "android")]
#[derive(Default)]
pub(crate) struct LogcatWriter {
    buffer: Vec<u8>,
}

#[cfg(target_os = "android")]
impl LogcatWriter {
    fn flush_line(&mut self, line: &[u8]) {
        use std::ffi::CString;
        let Ok(tag) = CString::new("fi_rust") else { return };
        let Ok(message) = CString::new(line) else { return };
        // SAFETY: both pointers are valid NUL-terminated C strings for the call.
        unsafe {
            android_log_sys::__android_log_write(
                android_log_sys::LogPriority::INFO as _,
                tag.as_ptr(),
                message.as_ptr(),
            );
        }
    }
}

#[cfg(target_os = "android")]
impl std::io::Write for LogcatWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.buffer.extend_from_slice(buf);
        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=end).collect();
            self.flush_line(&line[..end]);
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if !self.buffer.is_empty() {
            let line = std::mem::take(&mut self.buffer);
            self.flush_line(&line);
        }
        Ok(())
    }
}

#[cfg(target_os = "android")]
impl Drop for LogcatWriter {
    fn drop(&mut self) {
        let _ = std::io::Write::flush(self);
    }
}
