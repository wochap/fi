//! Device display names: validation and the generated default.

use crate::identity::DeviceId;

/// Largest accepted device name, in UTF-8 bytes after trimming.
pub const MAX_DEVICE_NAME_BYTES: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum DeviceNameError {
    #[error("device name is empty")]
    Empty,
    #[error("device name is longer than {MAX_DEVICE_NAME_BYTES} bytes")]
    TooLong,
}

/// Trims `name` and checks it is non-empty and at most 64 UTF-8 bytes.
pub fn normalize_device_name(name: &str) -> Result<String, DeviceNameError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        Err(DeviceNameError::Empty)
    } else if trimmed.len() > MAX_DEVICE_NAME_BYTES {
        Err(DeviceNameError::TooLong)
    } else {
        Ok(trimmed.to_owned())
    }
}

/// The name a device presents until the user names it: "Fi <8 hex>".
#[must_use]
pub fn generated_device_name(device: DeviceId) -> String {
    format!("Fi {}", &device.to_string()[..8])
}

/// Whether `name` is exactly the generated default for `device`.
#[must_use]
pub fn is_generated_device_name(name: &str, device: DeviceId) -> bool {
    name == generated_device_name(device)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device() -> DeviceId {
        DeviceId::from_public_key(&[7; 32])
    }

    #[test]
    fn whitespace_is_trimmed_and_blank_is_refused() {
        assert_eq!(
            normalize_device_name("  Gean's Pixel ").unwrap(),
            "Gean's Pixel"
        );
        assert_eq!(normalize_device_name(""), Err(DeviceNameError::Empty));
        assert_eq!(normalize_device_name(" \t\n "), Err(DeviceNameError::Empty));
    }

    #[test]
    fn length_is_counted_in_utf8_bytes_after_trimming() {
        // "é" is two bytes: 32 of them is exactly 64 bytes.
        let at_limit = "é".repeat(32);
        assert_eq!(
            normalize_device_name(&format!(" {at_limit} ")).unwrap(),
            at_limit
        );
        assert_eq!(
            normalize_device_name(&format!("{at_limit}a")),
            Err(DeviceNameError::TooLong)
        );
        assert_eq!(
            normalize_device_name(&"✓".repeat(22)),
            Err(DeviceNameError::TooLong)
        );
        assert!(normalize_device_name(&"✓".repeat(21)).is_ok());
    }

    #[test]
    fn generated_form_matches_the_device_prefix() {
        let device = device();
        let name = generated_device_name(device);
        assert_eq!(name, format!("Fi {}", &device.to_string()[..8]));
        assert!(is_generated_device_name(&name, device));
        assert!(!is_generated_device_name("Fi 00000000", device));
        assert!(!is_generated_device_name("Kitchen tablet", device));
        let other = DeviceId::from_public_key(&[8; 32]);
        assert!(!is_generated_device_name(&name, other));
    }
}
