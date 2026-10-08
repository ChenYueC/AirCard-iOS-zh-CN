//! First-use artwork backups via individual image transfers, never whole-card exports.
//! Durable journals return staged images on interruption.
use crate::{
    exploit::{self, AppDeviceTunnel, Logger},
    ffi_util,
};
use idevice::afc::{opcode::AfcFopenMode, AfcClient};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::{c_char, c_void},
    path::Path,
};

const CARDS: &str = "/var/mobile/Library/Passes/Cards";
pub const ARTWORK: &[&str] = &[
    "cardBackgroundCombined@3x.png",
    "diffuse@3x.png",
    "background@3x.png",
    "strip@3x.png",
    "cardBackgroundCombined@2x.png",
    "diffuse@2x.png",
    "background@2x.png",
    "strip@2x.png",
    "cardBackgroundCombined.pdf",
    "background.pdf",
    "strip.pdf",
];

#[derive(Serialize, Deserialize)]
struct Snapshot {
    version: u32,
    card: String,
    pairing: String,
    files: BTreeMap<String, String>,
}
#[derive(Serialize, Deserialize)]
struct Recovery {
    card: String,
    pairing: String,
    media: String,
    books: Option<Vec<u8>>,
    image_files: Vec<String>,
}

fn digest(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}
fn validate_card(card: &str) -> Result<(), String> {
    if !(20..=64).contains(&card.len())
        || !card
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_+=".contains(&b))
    {
        return Err("卡片标识无效，已停止文件操作。".into());
    }
    Ok(())
}
fn save_json(path: &Path, value: &impl Serialize) -> Result<(), String> {
    let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    let temp = path.with_extension("tmp");
    let mut file = std::fs::File::create(&temp).map_err(|e| e.to_string())?;
    std::io::Write::write_all(&mut file, &bytes).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(temp, path).map_err(|e| e.to_string())
}
fn load_snapshot(root: &Path, card: &str, pairing: &str) -> Result<Snapshot, String> {
    let snapshot: Snapshot = serde_json::from_slice(
        &std::fs::read(root.join("snapshot.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    if snapshot.version != 1
        || snapshot.card != card
        || snapshot.pairing != pairing
        || snapshot.files.is_empty()
    {
        return Err("备份不属于当前卡片或配对文件，请使用创建备份时的配对文件。".into());
    }
    for (name, hash) in &snapshot.files {
        if !ARTWORK.contains(&name.as_str())
            || digest(&std::fs::read(root.join("artwork").join(name)).map_err(|e| e.to_string())?)
                != *hash
        {
            return Err("原始卡面备份缺失或损坏，已停止操作。".into());
        }
    }
    Ok(snapshot)
}

async fn read_file(afc: &mut AfcClient, path: &str) -> Result<Vec<u8>, String> {
    let mut fd = afc
        .open(path, AfcFopenMode::RdOnly)
        .await
        .map_err(|e| format!("读取原始卡面失败：{e:?}"))?;
    let bytes = fd
        .read_entire()
        .await
        .map_err(|e| format!("读取原始卡面失败：{e:?}"));
    let closed = fd
        .close()
        .await
        .map_err(|e| format!("关闭原始卡面文件失败：{e:?}"));
    closed?;
    bytes
}
async fn recover(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    recovery: &Recovery,
    logger: &Logger,
) -> Result<(), String> {
    let names = afc
        .list_dir("/")
        .await
        .map_err(|e| format!("检查备份暂存目录失败：{e:?}"))?;
    if names.contains(&recovery.media) {
        let staged = afc
            .list_dir(&recovery.media)
            .await
            .map_err(|e| format!("检查暂存图片失败：{e:?}"))?;
        let present: Vec<String> = staged
            .into_iter()
            .filter(|name| name != "." && name != "..")
            .collect();
        let paths = image_transfer_paths(recovery, &present, true)?;
        if !paths.is_empty() {
            logger.log("正在将暂存卡面图片放回原位置…");
            move_images(tunnel, afc, recovery, &paths, logger).await?;
        }
        let remaining = afc
            .list_dir(&recovery.media)
            .await
            .map_err(|e| format!("确认图片归位失败：{e:?}"))?;
        if remaining.iter().any(|name| name != "." && name != "..") {
            return Err(
                "仍有卡面图片留在暂存目录，已保留图片与恢复记录，请保持 VPN 后重试。".into(),
            );
        }
        // Only remove an empty temporary directory; never recursively discard images.
        afc.remove(&recovery.media)
            .await
            .map_err(|e| format!("清理空图片暂存目录失败：{e:?}"))?;
    }
    exploit::restore_books_state(afc, &recovery.books).await
}

fn validate_recovery(recovery: &Recovery, card: &str, fingerprint: &str) -> Result<(), String> {
    let token = recovery.media.strip_prefix("aircard-artwork-");
    if recovery.card != card
        || recovery.pairing != fingerprint
        || !token
            .is_some_and(|value| value.len() == 24 && value.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err("恢复记录不属于当前卡片或配对文件，已停止操作。".into());
    }
    validate_image_names(&recovery.image_files)?;
    Ok(())
}

fn validate_image_names(names: &[String]) -> Result<(), String> {
    let unique: std::collections::BTreeSet<_> = names.iter().collect();
    if names.is_empty()
        || unique.len() != names.len()
        || names.iter().any(|name| !ARTWORK.contains(&name.as_str()))
    {
        return Err("图片恢复记录包含无效或重复文件名，已停止操作。".into());
    }
    Ok(())
}

fn image_transfer_paths(
    recovery: &Recovery,
    names: &[String],
    returning: bool,
) -> Result<Vec<(String, String)>, String> {
    let permitted = &recovery.image_files;
    validate_image_names(permitted)?;
    validate_card(&recovery.card)?;
    let token = recovery.media.strip_prefix("aircard-artwork-");
    if !token.is_some_and(|value| value.len() == 24 && value.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err("图片暂存目录无效。".into());
    }
    if !names.is_empty() {
        validate_image_names(names)?;
    }
    if names.iter().any(|name| !permitted.contains(name)) {
        return Err("暂存目录出现非卡面文件，已停止操作并保留恢复记录。".into());
    }
    Ok(names
        .iter()
        .map(|name| {
            if returning {
                (
                    format!("/var/mobile/Media/{}/{name}", recovery.media),
                    format!("{{link}}/{name}"),
                )
            } else {
                (
                    format!("{CARDS}/{}.pkpass/{name}", recovery.card),
                    format!("{}/{name}", recovery.media),
                )
            }
        })
        .collect())
}

async fn move_images(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    recovery: &Recovery,
    paths: &[(String, String)],
    logger: &Logger,
) -> Result<(), String> {
    let files: Vec<(&str, &[u8])> = paths.iter().map(|_| ("artwork", b"".as_slice())).collect();
    let assets: Vec<(&str, &str)> = paths
        .iter()
        .map(|(from, to)| (from.as_str(), to.as_str()))
        .collect();
    exploit::transfer_batch(
        tunnel,
        afc,
        &format!("{CARDS}/{}.pkpass", recovery.card),
        &files,
        Some(&assets),
        logger,
    )
    .await
}

async fn read_artwork_staged(
    pairing: &[u8],
    card: &str,
    root: &Path,
    requested: &[String],
    logger: &Logger,
) -> Result<BTreeMap<String, Vec<u8>>, String> {
    validate_image_names(requested)?;
    if root.join("recovery.json").exists() {
        return Err("存在未完成恢复记录，请先使用移除并恢复。".into());
    }
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let mut tunnel = exploit::connect_tunnel(pairing, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;
    let books = exploit::read_books_state(&mut afc).await?;
    let recovery = Recovery {
        card: card.into(),
        pairing: digest(pairing),
        media: format!("aircard-artwork-{}", hex::encode(rand_token())),
        books,
        image_files: requested.to_vec(),
    };
    let journal = root.join("recovery.json");
    // Save before creating or transferring anything on the device.
    save_json(&journal, &recovery)?;
    let captured = async {
        afc.mk_dir(&recovery.media)
            .await
            .map_err(|e| format!("创建图片暂存目录失败：{e:?}"))?;
        let paths = image_transfer_paths(&recovery, requested, false)?;
        logger.log("正在备份原始卡面…");
        move_images(&mut tunnel, &mut afc, &recovery, &paths, logger).await?;
        let names = afc
            .list_dir(&recovery.media)
            .await
            .map_err(|e| format!("读取图片暂存目录失败：{e:?}"))?;
        // Validate every received entry, not just the requested whitelist.
        let received: Vec<String> = names
            .into_iter()
            .filter(|name| name != "." && name != "..")
            .collect();
        image_transfer_paths(&recovery, &received, true)?;
        let mut images = BTreeMap::new();
        for name in received {
            let path = format!("{}/{name}", recovery.media);
            let info = afc
                .get_file_info(&path)
                .await
                .map_err(|e| format!("检查暂存图片失败：{e:?}"))?;
            if info.st_ifmt != "S_IFREG" || info.size == 0 || info.size > 32 * 1024 * 1024 {
                return Err("暂存图片类型或大小异常，已停止操作。".into());
            }
            let bytes = read_file(&mut afc, &path).await?;
            if bytes.len() != info.size {
                return Err("暂存图片读取不完整。".into());
            }
            images.insert(name, bytes);
        }
        if images.is_empty() {
            return Err("未取得任何卡面图片，未替换卡面。".into());
        }
        Ok::<_, String>(images)
    }
    .await;
    // Always put staged images back before permitting the caller to replace them.
    if let Err(error) = recover(&mut tunnel, &mut afc, &recovery, logger).await {
        return Err(format!("暂存图片归位未完成，恢复记录已保留：{error}"));
    }
    std::fs::remove_file(&journal).map_err(|e| e.to_string())?;
    captured
}

async fn backup(
    pairing_path: String,
    card: String,
    root_path: String,
    logger: &Logger,
) -> Result<(), String> {
    validate_card(&card)?;
    let root = Path::new(&root_path);
    if root.join("recovery.json").exists() {
        return Err("存在中断恢复记录，请先使用移除并恢复处理；未开始新的图片备份。".into());
    }
    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| e.to_string())?;
    let fingerprint = digest(&pairing_bytes);
    if root.join("snapshot.json").exists() {
        load_snapshot(root, &card, &fingerprint)?;
        logger.log("使用首次图片备份，不覆盖原始卡面。");
        return Ok(());
    }
    let requested: Vec<String> = ARTWORK.iter().map(|name| name.to_string()).collect();
    let images = read_artwork_staged(&pairing_bytes, &card, root, &requested, logger).await?;
    std::fs::create_dir_all(root.join("artwork")).map_err(|e| e.to_string())?;
    let mut files = BTreeMap::new();
    for (name, bytes) in images {
        let mut file =
            std::fs::File::create(root.join("artwork").join(&name)).map_err(|e| e.to_string())?;
        std::io::Write::write_all(&mut file, &bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        files.insert(name, digest(&bytes));
    }
    // Publish the receipt only after every local image has been copied.
    save_json(
        &root.join("snapshot.json"),
        &Snapshot {
            version: 1,
            card: card.clone(),
            pairing: fingerprint.clone(),
            files,
        },
    )?;
    load_snapshot(root, &card, &fingerprint)?;
    logger.log("原始卡面已备份。");
    Ok(())
}
fn rand_token() -> Vec<u8> {
    use std::time::{SystemTime, UNIX_EPOCH};
    Sha256::digest(
        format!(
            "{}-{:?}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)
        )
        .as_bytes(),
    )[..12]
        .to_vec()
}

async fn restore(
    pairing_path: String,
    card: String,
    root_path: String,
    logger: &Logger,
) -> Result<(), String> {
    validate_card(&card)?;
    let root = Path::new(&root_path);
    if !root.join("snapshot.json").exists() && !root.join("recovery.json").exists() {
        return Err("没有原始卡面备份，无法恢复。".into());
    }
    let pairing_bytes = std::fs::read(&pairing_path).map_err(|e| e.to_string())?;
    let fingerprint = digest(&pairing_bytes);
    let journal = root.join("recovery.json");
    if journal.exists() {
        let recovery: Recovery =
            serde_json::from_slice(&std::fs::read(&journal).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        validate_recovery(&recovery, &card, &fingerprint)?;
        let mut tunnel = exploit::connect_tunnel(&pairing_bytes, logger).await?;
        let mut afc = tunnel.connect_afc(logger).await?;
        // Return interrupted artwork transfers before writing the backup.
        recover(&mut tunnel, &mut afc, &recovery, logger).await?;
        std::fs::remove_file(&journal).map_err(|e| e.to_string())?;
        if !root.join("snapshot.json").exists() {
            logger.log("中断的归位处理完成；没有图片备份，未写入卡面。");
            return Ok(());
        }
    }
    let snapshot = load_snapshot(root, &card, &fingerprint)?;
    // Restore only the filenames captured in the validated original snapshot.
    // Read access is not a prerequisite for writing an existing local backup.
    let staging = root.join(format!("restore-{}", hex::encode(rand_token())));
    std::fs::create_dir(&staging).map_err(|e| e.to_string())?;
    for name in snapshot.files.keys() {
        std::fs::copy(root.join("artwork").join(name), staging.join(name))
            .map_err(|e| e.to_string())?;
    }
    let result = exploit::exploit_write_dir(
        pairing_path.clone(),
        staging.to_string_lossy().into_owned(),
        format!("{CARDS}/{card}.pkpass"),
        logger,
    )
    .await;
    let _ = std::fs::remove_dir_all(&staging);
    result?;
    // Reading via staging moves the just-restored image again, and an empty
    // staging directory cannot prove its final location or Wallet readability.
    // Keep restoration on the same write path used to apply a working skin.
    logger.log("原始卡面已写回，正在刷新钱包缓存…");
    let cache = root.join("cache-invalidation");
    std::fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    for name in ["FrontFace", "Preview", "PlaceHolder"] {
        std::fs::write(cache.join(name), b"corrupted").map_err(|e| e.to_string())?;
    }
    let mut cache_errors = Vec::new();
    for extension in ["cache", "pkcache"] {
        if let Err(error) = exploit::exploit_write_dir(
            pairing_path.clone(),
            cache.to_string_lossy().into_owned(),
            format!("{CARDS}/{card}.{extension}"),
            logger,
        )
        .await
        {
            logger.log(format!("{extension} 缓存刷新未完成：{error}"));
            cache_errors.push(format!("{extension}: {error}"));
        }
    }
    if !cache_errors.is_empty() {
        return Err(format!(
            "原始图片写入接口已返回成功，但缓存刷新未完成；卡片和原始备份已保留。请关闭钱包后重试恢复。原因：{}",
            cache_errors.join("；")
        ));
    }
    logger.log("钱包缓存已刷新。");
    Ok(())
}

pub unsafe fn run(
    pairing: *const c_char,
    card: *const c_char,
    root: *const c_char,
    restoring: bool,
    callback: exploit::ALLogCallback,
    context: *mut c_void,
    error: *mut *mut c_char,
) -> i32 {
    let pairing = ffi_util::opt_str(pairing, "");
    let card = ffi_util::opt_str(card, "");
    let root = ffi_util::opt_str(root, "");
    let context = context as usize;
    let result = ffi_util::run_with_large_stack("aircard-backup", move || {
        let logger = Logger {
            cb: callback,
            ctx: context as *mut c_void,
        };
        idevice_ffi::run_sync_local(async {
            if root.is_empty() {
                return Err("备份路径为空。".into());
            }
            if restoring {
                restore(pairing, card, root, &logger).await
            } else {
                backup(pairing, card, root, &logger).await
            }
        })
    });
    match result {
        Ok(Ok(())) => 0,
        failure => {
            let message = match failure {
                Ok(Err(e)) | Err(e) => e,
                _ => unreachable!(),
            };
            if !error.is_null() {
                *error = ffi_util::cstr(message);
            }
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .join(format!("aircard-backup-test-{}", hex::encode(rand_token())));
            std::fs::create_dir_all(path.join("artwork")).unwrap();
            std::fs::write(path.join("artwork/background@3x.png"), b"original artwork").unwrap();
            let snapshot = Snapshot {
                version: 1,
                card: "IWQhI5gvkGwF29BEzliYgahqwT8=".into(),
                pairing: "paired-device".into(),
                files: BTreeMap::from([("background@3x.png".into(), digest(b"original artwork"))]),
            };
            save_json(&path.join("snapshot.json"), &snapshot).unwrap();
            Self(path)
        }
        fn load(&self, pairing: &str) -> Result<Snapshot, String> {
            load_snapshot(&self.0, "IWQhI5gvkGwF29BEzliYgahqwT8=", pairing)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn snapshot_requires_matching_device_and_card() {
        let fixture = Fixture::new();
        assert!(fixture.load("paired-device").is_ok());
        assert!(fixture.load("other-device").is_err());
        assert!(
            load_snapshot(&fixture.0, "nglMhbqt7jcftoIuMa8m1DEp31E=", "paired-device").is_err()
        );
    }
    #[test]
    fn corrupt_or_missing_original_prevents_restore() {
        let fixture = Fixture::new();
        let path = fixture.0.join("artwork/background@3x.png");
        std::fs::write(&path, b"replacement artwork").unwrap();
        assert!(fixture.load("paired-device").is_err());
        std::fs::remove_file(path).unwrap();
        assert!(fixture.load("paired-device").is_err());
    }
    #[test]
    fn backup_validation_does_not_overwrite_original() {
        let fixture = Fixture::new();
        let before = std::fs::read(fixture.0.join("snapshot.json")).unwrap();
        fixture.load("paired-device").unwrap();
        fixture.load("paired-device").unwrap();
        assert_eq!(
            before,
            std::fs::read(fixture.0.join("snapshot.json")).unwrap()
        );
        assert_eq!(
            b"original artwork",
            std::fs::read(fixture.0.join("artwork/background@3x.png"))
                .unwrap()
                .as_slice()
        );
    }
    #[test]
    fn reject_paths_and_non_artwork_files() {
        assert!(validate_card("IWQhI5gvkGwF29BEzliYgahqwT8=").is_ok());
        for card in [
            "../IWQhI5gvkGwF29BEzliYgahqwT8=",
            "IWQhI5gvkGwF29BEzliYgahqwT8=/",
            "short",
        ] {
            assert!(validate_card(card).is_err());
        }
        let fixture = Fixture::new();
        let mut snapshot = fixture.load("paired-device").unwrap();
        snapshot
            .files
            .insert("../outside".into(), digest(b"original artwork"));
        // Write a new receipt through a separate path to work on Windows too.
        std::fs::remove_file(fixture.0.join("snapshot.json")).unwrap();
        save_json(&fixture.0.join("snapshot.json"), &snapshot).unwrap();
        assert!(fixture.load("paired-device").is_err());
    }

    #[test]
    fn recovery_rejects_foreign_device_card_and_unsafe_paths() {
        let card = "IWQhI5gvkGwF29BEzliYgahqwT8=";
        let mut recovery = Recovery {
            card: card.into(),
            pairing: "device".into(),
            media: "aircard-artwork-0123456789abcdef01234567".into(),
            books: None,
            image_files: vec!["background@3x.png".into()],
        };
        assert!(validate_recovery(&recovery, card, "device").is_ok());
        assert!(validate_recovery(&recovery, card, "other-device").is_err());
        assert!(validate_recovery(&recovery, "other-card", "device").is_err());
        recovery.media = "aircard-artwork-../../Library/Passes".into();
        assert!(validate_recovery(&recovery, card, "device").is_err());
    }

    fn image_recovery() -> Recovery {
        Recovery {
            card: "IWQhI5gvkGwF29BEzliYgahqwT8=".into(),
            pairing: "device".into(),
            media: "aircard-artwork-0123456789abcdef01234567".into(),
            books: Some(b"original books state".to_vec()),
            image_files: vec!["background@3x.png".into(), "strip.pdf".into()],
        }
    }

    #[test]
    fn image_transfers_only_address_individual_artwork_and_return_to_same_names() {
        let recovery = image_recovery();
        validate_recovery(&recovery, &recovery.card, "device").unwrap();
        let names = &recovery.image_files;
        let outgoing = image_transfer_paths(&recovery, names, false).unwrap();
        let returning = image_transfer_paths(&recovery, names, true).unwrap();
        for ((from, to), name) in outgoing.iter().zip(names) {
            assert_eq!(from, &format!("{CARDS}/{}.pkpass/{name}", recovery.card));
            assert_eq!(to, &format!("{}/{name}", recovery.media));
            assert!(!from.ends_with(".pkpass"));
        }
        for ((from, to), name) in returning.iter().zip(names) {
            assert_eq!(
                from,
                &format!("/var/mobile/Media/{}/{name}", recovery.media)
            );
            assert_eq!(to, &format!("{{link}}/{name}"));
        }
        // An interrupted partial batch recovers only the files actually staged.
        let subset = vec!["strip.pdf".into()];
        assert_eq!(
            image_transfer_paths(&recovery, &subset, true)
                .unwrap()
                .len(),
            1
        );
        assert!(image_transfer_paths(&recovery, &[], true)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn image_journals_reject_foreign_files_duplicates_and_whole_card_paths() {
        let mut recovery = image_recovery();
        for name in [
            "pass.json",
            "../background@3x.png",
            "card.pkpass",
            "diffuse@3x.png",
        ] {
            assert!(image_transfer_paths(&recovery, &[name.into()], true).is_err());
        }
        recovery.image_files = vec!["strip.pdf".into(), "strip.pdf".into()];
        assert!(validate_recovery(&recovery, &recovery.card, "device").is_err());
        recovery.image_files = vec!["../outside".into()];
        assert!(validate_recovery(&recovery, &recovery.card, "device").is_err());
    }

    #[test]
    fn journal_roundtrip_preserves_recovery_scope_and_rejects_whole_card_records() {
        let recovery = image_recovery();
        let bytes = serde_json::to_vec(&recovery).unwrap();
        let decoded: Recovery = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(decoded.image_files, recovery.image_files);
        assert_eq!(decoded.books, recovery.books);
        validate_recovery(&decoded, &recovery.card, "device").unwrap();
        assert!(serde_json::from_str::<Recovery>(
            r#"{
            "card":"IWQhI5gvkGwF29BEzliYgahqwT8=", "pairing":"device",
            "media":"aircard-original-0123456789abcdef01234567", "books":null
        }"#,
        ).is_err());
    }
}
