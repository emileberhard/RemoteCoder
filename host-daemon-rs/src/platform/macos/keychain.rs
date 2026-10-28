use std::ffi::c_void;

use anyhow::{Result, bail};

const CALLER_SECURITY_SESSION: u32 = u32::MAX;
const SESSION_HAS_GRAPHIC_ACCESS: u32 = 0x0010;
const NO_DEFAULT_KEYCHAIN: i32 = -25307;
const UNLOCK_STATE: u32 = 1;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SessionGetInfo(session: u32, session_id: *mut u32, attributes: *mut u32) -> i32;
    fn SecKeychainCopyDefault(keychain: *mut *mut c_void) -> i32;
    fn SecKeychainGetStatus(keychain: *mut c_void, status: *mut u32) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(object: *const c_void);
}

pub(crate) fn lookup_would_prompt() -> Result<bool> {
    let mut attributes = 0;
    // SAFETY: the caller-session constant is valid input, the session id is
    // optional and `attributes` is a writable local.
    let session = unsafe {
        SessionGetInfo(
            CALLER_SECURITY_SESSION,
            std::ptr::null_mut(),
            &mut attributes,
        )
    };
    if session != 0 {
        bail!("reading the security session failed (OSStatus {session})");
    }
    if attributes & SESSION_HAS_GRAPHIC_ACCESS == 0 {
        return Ok(false);
    }
    let mut keychain = std::ptr::null_mut();
    // SAFETY: the out pointer refers to a writable local; on success the
    // keychain reference is owned here and released below.
    let copied = unsafe { SecKeychainCopyDefault(&mut keychain) };
    if copied == NO_DEFAULT_KEYCHAIN {
        return Ok(false);
    }
    if copied != 0 || keychain.is_null() {
        bail!("reading the default keychain failed (OSStatus {copied})");
    }
    let mut status = 0;
    // SAFETY: `keychain` is the live reference copied above and `status` is a
    // writable local; the reference is released exactly once afterwards.
    let read = unsafe {
        let read = SecKeychainGetStatus(keychain, &mut status);
        CFRelease(keychain);
        read
    };
    if read != 0 {
        bail!("reading the default keychain status failed (OSStatus {read})");
    }
    Ok(status & UNLOCK_STATE == 0)
}
