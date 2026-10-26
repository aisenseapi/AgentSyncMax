//! Validate local storage without confusing Cloud Files placeholders with links.
//! This check reads attributes/tags only. It neither follows a leaf reparse point
//! nor hydrates file data. It is not an atomic lock against a later path swap.
use std::fs::Metadata;
use std::path::Path;

#[cfg(any(windows, test))]
fn cloud_reparse_tag(tag: u32) -> bool {
    // IO_REPARSE_TAG_CLOUD through IO_REPARSE_TAG_CLOUD_F. Junctions,
    // symlinks and unknown provider tags are deliberately not accepted.
    tag & 0xffff_0fff == 0x9000_001a
}

pub(crate) fn validate_stored_path(
    path: &Path,
    metadata: &Metadata,
    require_local_data: bool,
) -> Result<(), String> {
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "Lenker er ikke tillatt i avklaringslageret: {}",
            path.display()
        ));
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_ATTRIBUTE_OFFLINE, FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS,
            FILE_ATTRIBUTE_RECALL_ON_OPEN, FILE_ATTRIBUTE_REPARSE_POINT,
        };
        let mut attributes = metadata.file_attributes();
        if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            let (actual_attributes, tag) = attribute_tag(path)?;
            if actual_attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 && !cloud_reparse_tag(tag) {
                return Err(format!(
                    "Utrygt eller ukjent reparsepunkt i avklaringslageret: {}",
                    path.display()
                ));
            }
            // Some Cloud Files API surfaces omit placeholder bits on an
            // opened handle. Never use that to discard an offline/recall bit
            // observed by the preceding metadata query.
            attributes |= actual_attributes;
        }
        if require_local_data
            && attributes
                & (FILE_ATTRIBUTE_OFFLINE
                    | FILE_ATTRIBUTE_RECALL_ON_OPEN
                    | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)
                != 0
        {
            return Err(format!(
                "Dataposten er ikke tilgjengelig lokalt. Gjør filen tilgjengelig offline først: {}",
                path.display()
            ));
        }
    }
    #[cfg(not(windows))]
    let _ = require_local_data;
    Ok(())
}

#[cfg(windows)]
fn attribute_tag(path: &Path) -> Result<(u32, u32), String> {
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FileAttributeTagInfo, GetFileInformationByHandleEx, FILE_ATTRIBUTE_TAG_INFO,
        FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    if wide.contains(&0) {
        return Err("Ugyldig nulltegn i lagringsstien.".into());
    }
    wide.push(0);
    // Zero access is sufficient for attribute queries. OPEN_REPARSE_POINT
    // prevents following the leaf link; BACKUP_SEMANTICS permits directories.
    // No generic read access or file-data read is requested.
    let raw = unsafe {
        CreateFileW(
            wide.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        )
    };
    if raw == INVALID_HANDLE_VALUE {
        return Err(format!(
            "Kan ikke verifisere lagringspunktet {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    // OwnedHandle closes on every success/error path.
    let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
    let mut info: FILE_ATTRIBUTE_TAG_INFO = unsafe { std::mem::zeroed() };
    if unsafe {
        GetFileInformationByHandleEx(
            handle.as_raw_handle(),
            FileAttributeTagInfo,
            &mut info as *mut _ as *mut _,
            std::mem::size_of_val(&info) as u32,
        )
    } == 0
    {
        return Err(format!(
            "Kan ikke lese reparse-tag for {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    Ok((info.FileAttributes, info.ReparseTag))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permits_only_the_documented_cloud_tag_family() {
        for variant in 0..=15 {
            assert!(cloud_reparse_tag(0x9000_001a | (variant << 12)));
        }
        for tag in [
            0,
            0xa000_0003,
            0xa000_000c,
            0x9000_101b,
            0x9001_001a,
            0xb000_001a,
        ] {
            assert!(!cloud_reparse_tag(tag), "unexpected accepted tag {tag:x}");
        }
    }

    #[test]
    fn ordinary_local_file_and_directory_remain_supported() {
        let directory = std::env::temp_dir().join(format!(
            "storage-safety-{}-{}",
            std::process::id(),
            super::super::now_unix_ms()
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("fixture.json");
        std::fs::write(&path, "{}").unwrap();
        let result = (|| -> Result<(), String> {
            validate_stored_path(
                &directory,
                &std::fs::symlink_metadata(&directory).unwrap(),
                false,
            )?;
            validate_stored_path(&path, &std::fs::symlink_metadata(&path).unwrap(), true)?;
            #[cfg(windows)]
            assert_eq!(attribute_tag(&path).unwrap().1, 0);
            Ok(())
        })();
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(directory).unwrap();
        result.unwrap();
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "Explicit read-only check of the operator-selected real Dropbox store"]
    fn live_cloud_store_metadata_only() {
        use std::os::windows::fs::MetadataExt;
        let home = super::super::resolve_agentsync_home().unwrap();
        let missions = home.join("missions");
        let metadata = std::fs::symlink_metadata(&missions).unwrap();
        println!(
            "Rust symlink metadata attributes={:#x}; former broad reparse guard would reject={}",
            metadata.file_attributes(),
            metadata.file_attributes() & 0x400 != 0
        );
        validate_stored_path(&missions, &metadata, false).unwrap();
        let (attributes, tag) = attribute_tag(&missions).unwrap();
        println!("Mission store metadata: attributes={attributes:#x}, reparseTag={tag:#x}; no file data read");
    }
}
