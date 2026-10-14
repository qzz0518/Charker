//! Everything under `--storage`: `pairing.json` (onboarding identity) and the
//! Matter KV blobs (`k_XXXX`, fabrics/ACLs/OnOff/energy...). Every write is
//! temp file + rename, so a crash or `exit` never leaves a torn file behind.

use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use rs_matter::error::{Error, ErrorCode};
use rs_matter::persist::KvBlobStore;
use serde::{Deserialize, Serialize};

const PAIRING_FILE: &str = "pairing.json";

/// Generated on first launch, then fixed for the life of the storage dir.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pairing {
    pub passcode: u32,
    pub discriminator: u16,
    /// 16 hex chars; SerialNumber, and UniqueID as `charker-<serial>`.
    pub serial: String,
}

impl Pairing {
    pub fn generate() -> Self {
        let passcode = loop {
            let p = rand::random_range(1..=99_999_998u32);
            if valid_passcode(p) {
                break p;
            }
        };
        Self {
            passcode,
            discriminator: rand::random_range(0..=0xFFFu16),
            serial: rand::random::<[u8; 8]>()
                .iter()
                .map(|b| format!("{b:02X}"))
                .collect(),
        }
    }

    fn validate(&self) -> Result<(), String> {
        if !valid_passcode(self.passcode) {
            return Err(format!("invalid passcode {}", self.passcode));
        }
        if self.discriminator > 0xFFF {
            return Err(format!(
                "discriminator {} exceeds 12 bits",
                self.discriminator
            ));
        }
        if self.serial.len() != 16 || !self.serial.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("serial {:?} is not 16 hex chars", self.serial));
        }
        Ok(())
    }

    /// Loads `<dir>/pairing.json`, creating the dir and the file on first launch.
    pub fn load_or_create(dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
        let path = dir.join(PAIRING_FILE);
        match fs::read(&path) {
            Ok(bytes) => {
                let p: Self = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                p.validate()
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                Ok(p)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let p = Self::generate();
                let json = serde_json::to_vec_pretty(&p).map_err(|e| e.to_string())?;
                write_atomic(&path, &json).map_err(|e| format!("{}: {e}", path.display()))?;
                Ok(p)
            }
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }
}

/// Matter setup passcode rules: 00000001..=99999998, minus the repeated-digit
/// codes (11111111...88888888) and 12345678 / 87654321.
pub fn valid_passcode(p: u32) -> bool {
    (1..=99_999_998).contains(&p)
        && !p.is_multiple_of(11_111_111)
        && p != 12_345_678
        && p != 87_654_321
}

fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let mut file = fs::File::create(&tmp)?;
    file.write_all(data)?;
    file.sync_all()?;
    fs::rename(&tmp, path)
}

/// Drop-in for rs-matter's `DirKvBlobStore` (same `k_XXXX` names) with atomic writes.
pub struct KvStore(PathBuf);

impl KvStore {
    pub fn new(dir: PathBuf) -> Self {
        Self(dir)
    }

    fn path(&self, key: u16) -> PathBuf {
        self.0.join(format!("k_{key:04x}"))
    }
}

impl KvBlobStore for KvStore {
    fn load<'a>(&mut self, key: u16, buf: &'a mut [u8]) -> Result<Option<&'a [u8]>, Error> {
        let mut file = match fs::File::open(self.path(key)) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let mut len = 0;
        loop {
            if len == buf.len() {
                // Full buffer: the blob fits only if the file ends right here.
                if file.read(&mut [0u8; 1])? != 0 {
                    return Err(ErrorCode::BufferTooSmall.into());
                }
                break;
            }
            let n = file.read(&mut buf[len..])?;
            if n == 0 {
                break;
            }
            len += n;
        }
        Ok(Some(&buf[..len]))
    }

    fn store(&mut self, key: u16, data: &[u8], _buf: &mut [u8]) -> Result<(), Error> {
        Ok(write_atomic(&self.path(key), data)?)
    }

    fn remove(&mut self, key: u16, _buf: &mut [u8]) -> Result<(), Error> {
        match fs::remove_file(self.path(key)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch_dir(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("charker-matter-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn passcode_validity() {
        for bad in [
            0,
            11_111_111,
            22_222_222,
            55_555_555,
            88_888_888,
            99_999_999,
            12_345_678,
            87_654_321,
            100_000_000,
        ] {
            assert!(!valid_passcode(bad), "{bad}");
        }
        for good in [1, 20_202_021, 24_681_357, 99_999_998] {
            assert!(valid_passcode(good), "{good}");
        }
        for _ in 0..1000 {
            Pairing::generate().validate().unwrap();
        }
    }

    #[test]
    fn pairing_is_created_once_then_kept() {
        let dir = scratch_dir("pairing").join("nested");
        let a = Pairing::load_or_create(&dir).unwrap();
        let b = Pairing::load_or_create(&dir).unwrap();
        assert_eq!(a, b);
        assert!(!dir.join("pairing.json.tmp").exists());
        fs::write(
            dir.join(PAIRING_FILE),
            br#"{"passcode":12345678,"discriminator":1,"serial":"0011223344556677"}"#,
        )
        .unwrap();
        assert!(Pairing::load_or_create(&dir).is_err());
        fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    }

    #[test]
    fn kv_store_roundtrip() {
        let dir = scratch_dir("kv");
        fs::create_dir_all(&dir).unwrap();
        let mut kv = KvStore::new(dir.clone());
        let mut buf = [0u8; 8];
        assert_eq!(kv.load(1, &mut buf).unwrap(), None);
        kv.store(1, b"abc", &mut []).unwrap();
        assert_eq!(kv.load(1, &mut buf).unwrap(), Some(&b"abc"[..]));
        assert!(dir.join("k_0001").exists());
        kv.store(1, b"12345678", &mut []).unwrap();
        assert_eq!(kv.load(1, &mut buf).unwrap(), Some(&b"12345678"[..]));
        kv.store(1, b"123456789", &mut []).unwrap();
        assert_eq!(
            kv.load(1, &mut buf).unwrap_err().code(),
            ErrorCode::BufferTooSmall
        );
        kv.remove(1, &mut []).unwrap();
        kv.remove(1, &mut []).unwrap();
        assert_eq!(kv.load(1, &mut buf).unwrap(), None);
        fs::remove_dir_all(dir).unwrap();
    }
}
