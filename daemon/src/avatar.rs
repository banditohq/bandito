//! Agent avatar pictures on disk: `<data>/avatars/<agent id>.png` or `.jpg`, stored as sent
//! (see docs/ARCHITECTURE.md#capabilities). Only the RPC layer calls these, after checking the agent exists.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Largest picture accepted, in bytes after base64 decoding.
pub const MAX_BYTES: usize = 1024 * 1024;

/// The picture's MIME type and file extension, from its first bytes. `None` for anything but PNG or JPEG.
pub fn sniff(bytes: &[u8]) -> Option<(&'static str, &'static str)> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(("image/png", "png"))
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(("image/jpeg", "jpg"))
    } else {
        None
    }
}

/// The folder of the pictures.
pub fn dir(data_home: &Path) -> PathBuf {
    data_home.join("avatars")
}

/// The picture of an agent on disk, with its MIME type: `None` if there is none.
pub fn find(data_home: &Path, agent_id: &str) -> Option<(PathBuf, &'static str)> {
    [("png", "image/png"), ("jpg", "image/jpeg")]
        .into_iter()
        .map(|(ext, mime)| (dir(data_home).join(format!("{agent_id}.{ext}")), mime))
        .find(|(path, _)| path.is_file())
}

/// Store the picture, replacing any earlier one of the agent. Written to a temporary file first, then renamed.
pub fn write(data_home: &Path, agent_id: &str, bytes: &[u8]) -> Result<()> {
    let (_, ext) = sniff(bytes).context("not a PNG or JPEG picture")?;
    let folder = dir(data_home);
    std::fs::create_dir_all(&folder).context("create the avatars folder")?;
    let tmp = folder.join(format!(".{agent_id}.tmp"));
    std::fs::write(&tmp, bytes).context("write the avatar picture")?;
    remove(data_home, agent_id);
    std::fs::rename(&tmp, folder.join(format!("{agent_id}.{ext}"))).context("place the avatar picture")?;
    Ok(())
}

/// Delete the agent's picture, whatever its extension. A missing file is not an error.
pub fn remove(data_home: &Path, agent_id: &str) {
    for ext in ["png", "jpg"] {
        let _ = std::fs::remove_file(dir(data_home).join(format!("{agent_id}.{ext}")));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";
    const JPG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0, 16];

    fn home(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("bandito-avatar-{name}-{}", crate::store::new_id()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn sniff_accepts_png_and_jpeg_only() {
        assert_eq!(sniff(PNG), Some(("image/png", "png")));
        assert_eq!(sniff(JPG), Some(("image/jpeg", "jpg")));
        assert_eq!(sniff(b"GIF89a"), None);
        assert_eq!(sniff(b"\x89PNG"), None, "a short PNG signature is not a PNG");
        assert_eq!(sniff(b""), None);
    }

    #[test]
    fn write_replaces_the_other_extension_and_remove_clears_both() {
        let h = home("replace");
        write(&h, "agent-1", PNG).unwrap();
        assert_eq!(find(&h, "agent-1").map(|(_, m)| m), Some("image/png"));
        write(&h, "agent-1", JPG).unwrap();
        let (path, mime) = find(&h, "agent-1").unwrap();
        assert_eq!(
            (path.extension().unwrap(), mime),
            (std::ffi::OsStr::new("jpg"), "image/jpeg")
        );
        assert!(!dir(&h).join("agent-1.png").exists());
        remove(&h, "agent-1");
        assert!(find(&h, "agent-1").is_none());
        remove(&h, "agent-1");
        std::fs::remove_dir_all(&h).ok();
    }

    #[test]
    fn write_refuses_anything_but_a_picture() {
        let h = home("refuse");
        assert!(write(&h, "agent-1", b"<svg></svg>").is_err());
        assert!(find(&h, "agent-1").is_none());
        std::fs::remove_dir_all(&h).ok();
    }
}
