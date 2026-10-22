//! [`request_quit`] sends the standard `aevt/quit` Apple Event to one process,
//! which is what `NSRunningApplication.terminate()` does. The app runs its own
//! termination path and can shut down the helpers it owns, which SIGTERM or
//! SIGKILL skip.

use anyhow::Result;

/// Asks the application running as `pid` to quit normally. Success means the
/// request was queued, not that the app has exited; callers wait for the exit.
#[cfg(target_os = "macos")]
pub(crate) fn request_quit(pid: i32) -> Result<()> {
    apple_events::send_quit(pid)
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn request_quit(pid: i32) -> Result<()> {
    anyhow::bail!("a normal application quit is unavailable on this platform (pid {pid})")
}

#[cfg(target_os = "macos")]
mod apple_events {
    use std::ffi::c_void;

    use anyhow::{Result, bail};

    /// `AEDesc` from `AEDataModel.h`: a four-char type code and an opaque
    /// data handle.
    #[repr(C)]
    struct AeDesc {
        descriptor_type: u32,
        data_handle: *mut c_void,
    }

    impl AeDesc {
        const NULL: AeDesc = AeDesc {
            descriptor_type: TYPE_NULL,
            data_handle: std::ptr::null_mut(),
        };
    }

    const fn four_char(code: &[u8; 4]) -> u32 {
        u32::from_be_bytes(*code)
    }

    const TYPE_NULL: u32 = four_char(b"null");
    const TYPE_KERNEL_PROCESS_ID: u32 = four_char(b"kpid");
    const CORE_EVENT_CLASS: u32 = four_char(b"aevt");
    const QUIT_APPLICATION: u32 = four_char(b"quit");
    const AUTO_GENERATE_RETURN_ID: i16 = -1;
    const ANY_TRANSACTION_ID: i32 = 0;
    const NO_REPLY: i32 = 0x0000_0001;
    const NEVER_INTERACT: i32 = 0x0000_0010;
    const DEFAULT_TIMEOUT: isize = -1;
    const PROCESS_NOT_FOUND: i32 = -600;
    const EVENT_NOT_PERMITTED: i32 = -1743;

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn AECreateDesc(
            type_code: u32,
            data: *const c_void,
            data_size: isize,
            result: *mut AeDesc,
        ) -> i16;
        fn AECreateAppleEvent(
            event_class: u32,
            event_id: u32,
            target: *const AeDesc,
            return_id: i16,
            transaction_id: i32,
            result: *mut AeDesc,
        ) -> i16;
        fn AESendMessage(
            event: *const AeDesc,
            reply: *mut AeDesc,
            send_mode: i32,
            timeout_ticks: isize,
        ) -> i32;
        fn AEDisposeDesc(desc: *mut AeDesc) -> i16;
    }

    /// Owns one descriptor and disposes it on every exit path.
    struct OwnedDesc(AeDesc);

    impl Drop for OwnedDesc {
        fn drop(&mut self) {
            // SAFETY: the descriptor was initialized by an AE constructor (or
            // is the null descriptor, which AEDisposeDesc accepts) and is
            // disposed exactly once here.
            unsafe {
                AEDisposeDesc(&mut self.0);
            }
        }
    }

    pub(super) fn send_quit(pid: i32) -> Result<()> {
        if pid <= 0 {
            bail!("cannot address a quit request to pid {pid}");
        }
        let mut target = OwnedDesc(AeDesc::NULL);
        // SAFETY: `pid` outlives the call, its exact size is passed, and the
        // result points at a writable descriptor owned by `target`.
        let status = unsafe {
            AECreateDesc(
                TYPE_KERNEL_PROCESS_ID,
                (&raw const pid).cast(),
                std::mem::size_of::<i32>() as isize,
                &mut target.0,
            )
        };
        if status != 0 {
            bail!("could not address pid {pid} for a quit request (OSErr {status})");
        }
        let mut event = OwnedDesc(AeDesc::NULL);
        // SAFETY: `target` is an initialized address descriptor and the
        // result points at a writable descriptor owned by `event`.
        let status = unsafe {
            AECreateAppleEvent(
                CORE_EVENT_CLASS,
                QUIT_APPLICATION,
                &target.0,
                AUTO_GENERATE_RETURN_ID,
                ANY_TRANSACTION_ID,
                &mut event.0,
            )
        };
        if status != 0 {
            bail!("could not build a quit request for pid {pid} (OSErr {status})");
        }
        // SAFETY: `event` is an initialized Apple Event. A no-reply send
        // accepts a null reply pointer.
        let status = unsafe {
            AESendMessage(
                &event.0,
                std::ptr::null_mut(),
                NO_REPLY | NEVER_INTERACT,
                DEFAULT_TIMEOUT,
            )
        };
        match status {
            0 => Ok(()),
            PROCESS_NOT_FOUND => {
                bail!("pid {pid} is not a running application (OSStatus {status})")
            }
            EVENT_NOT_PERMITTED => {
                bail!("macOS did not permit a quit request to pid {pid} (OSStatus {status})")
            }
            _ => bail!("the quit request to pid {pid} failed (OSStatus {status})"),
        }
    }
}
