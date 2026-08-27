use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf, Prefix};

use anyhow::{Context, Result};
use windows::Win32::Storage::FileSystem::GetDriveTypeW;
use windows::Win32::System::WindowsProgramming::{
    DRIVE_NO_ROOT_DIR, DRIVE_REMOTE, DRIVE_UNKNOWN,
};
use windows::core::PCWSTR;

pub fn validate_local_media_path(path: &Path) -> Result<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .context("resolving the current directory")?
            .join(path)
    };
    ensure_local_drive(&absolute)?;

    let canonical = absolute.canonicalize().with_context(|| {
        format!(
            "input does not exist or cannot be resolved: {}",
            path.display()
        )
    })?;
    ensure_local_drive(&canonical)?;
    Ok(canonical)
}

fn ensure_local_drive(path: &Path) -> Result<()> {
    let drive = match path.components().next() {
        Some(Component::Prefix(prefix)) => match prefix.kind() {
            Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => drive,
            Prefix::UNC(..) | Prefix::VerbatimUNC(..) => {
                anyhow::bail!("network media paths are not permitted: {}", path.display())
            }
            Prefix::DeviceNS(..) | Prefix::Verbatim(..) => {
                anyhow::bail!("device media paths are not permitted: {}", path.display())
            }
        },
        _ => anyhow::bail!(
            "media path must resolve to a local Windows drive: {}",
            path.display()
        ),
    };

    let root = format!("{}:\\", char::from(drive));
    let wide: Vec<u16> = OsStr::new(&root).encode_wide().chain(Some(0)).collect();
    let drive_type = unsafe { GetDriveTypeW(PCWSTR(wide.as_ptr())) };
    if drive_type == DRIVE_REMOTE {
        anyhow::bail!(
            "network-mapped media drives are not permitted: {}",
            path.display()
        );
    }
    if drive_type == DRIVE_UNKNOWN || drive_type == DRIVE_NO_ROOT_DIR {
        anyhow::bail!(
            "media drive is unavailable or unidentified: {}",
            path.display()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_local_media_path;
    use std::path::Path;

    #[test]
    fn rejects_unc_before_filesystem_access() {
        assert!(validate_local_media_path(Path::new(r"\\server\share\movie.mp4")).is_err());
        assert!(validate_local_media_path(Path::new(r"\\?\UNC\server\share\movie.mp4")).is_err());
    }

    #[test]
    fn accepts_an_existing_local_file() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("media file.mp4");
        std::fs::write(&path, b"fixture").expect("write fixture");

        let validated = validate_local_media_path(&path).expect("validate local path");
        assert_eq!(
            validated,
            path.canonicalize().expect("canonical fixture path")
        );
    }
}
