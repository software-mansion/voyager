use rand::Rng;
use rand::distr::Alphanumeric;
use std::io::{Error, ErrorKind, Result};
use std::net::TcpListener;
use std::path::Path;

const SECRET_KEY_BASE_FILE: &str = "secret_key_base";
/// Length, in characters, of the generated `SECRET_KEY_BASE`. Matches the
/// 64-character default produced by Phoenix's `mix phx.gen.secret`.
const SECRET_KEY_BASE_LEN: usize = 64;

/// Returns the first TCP port available on `127.0.0.1` at or after `start`.
pub fn available_port(start: u16) -> Result<u16> {
    (start..=u16::MAX)
        .find(|&port| TcpListener::bind(("127.0.0.1", port)).is_ok())
        .ok_or_else(|| Error::new(ErrorKind::AddrNotAvailable, "no available localhost port"))
}

/// Reads the persisted `SECRET_KEY_BASE` from `data_dir`, generating and
/// persisting a new one when it is missing or not the expected length.
pub fn secret_key_base(data_dir: &Path) -> String {
    let path = data_dir.join(SECRET_KEY_BASE_FILE);

    match std::fs::read_to_string(&path) {
        Ok(secret) if secret.trim().len() == SECRET_KEY_BASE_LEN => secret.trim().to_string(),
        _ => generate_secret_key_base(&path),
    }
}

fn generate_secret_key_base(path: &Path) -> String {
    let secret = random_secret(SECRET_KEY_BASE_LEN);
    std::fs::write(path, &secret).expect("failed to persist SECRET_KEY_BASE");
    secret
}

/// Builds a string of `len` random ASCII alphanumeric characters.
fn random_secret(len: usize) -> String {
    rand::rng()
        .sample_iter(Alphanumeric)
        .take(len)
        .map(char::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn available_port_skips_bound_ports() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let occupied_port = listener.local_addr().unwrap().port();

        let port = available_port(occupied_port).unwrap();

        assert!(port > occupied_port);
    }

    #[test]
    fn secret_key_base_generates_and_reuses_persisted_secret() {
        let data_dir = temp_data_dir("secret-reuse");
        std::fs::create_dir_all(&data_dir).unwrap();

        let secret = secret_key_base(&data_dir);
        let persisted_secret =
            std::fs::read_to_string(data_dir.join(SECRET_KEY_BASE_FILE)).unwrap();
        let reused_secret = secret_key_base(&data_dir);

        assert_eq!(secret.len(), SECRET_KEY_BASE_LEN);
        assert!(secret.chars().all(|char| char.is_ascii_alphanumeric()));
        assert_eq!(secret, persisted_secret);
        assert_eq!(secret, reused_secret);

        std::fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn secret_key_base_replaces_invalid_persisted_secret() {
        let data_dir = temp_data_dir("secret-invalid");
        std::fs::create_dir_all(&data_dir).unwrap();
        std::fs::write(data_dir.join(SECRET_KEY_BASE_FILE), "too-short").unwrap();

        let secret = secret_key_base(&data_dir);

        assert_eq!(secret.len(), SECRET_KEY_BASE_LEN);
        assert_ne!(secret, "too-short");

        std::fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn secret_key_base_replaces_wrong_length_persisted_secret() {
        let data_dir = temp_data_dir("secret-wrong-length");
        std::fs::create_dir_all(&data_dir).unwrap();
        let too_long = "a".repeat(SECRET_KEY_BASE_LEN + 1);
        std::fs::write(data_dir.join(SECRET_KEY_BASE_FILE), &too_long).unwrap();

        let secret = secret_key_base(&data_dir);

        assert_eq!(secret.len(), SECRET_KEY_BASE_LEN);
        assert_ne!(secret, too_long);

        std::fs::remove_dir_all(data_dir).unwrap();
    }

    fn temp_data_dir(test_name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "voyager-utils-test-{test_name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        path
    }
}
