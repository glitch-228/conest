use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const RETRY_DELAY: Duration = Duration::from_millis(500);
const MAX_ATTEMPTS: usize = 120;

fn main() {
    if let Err(error) = run() {
        eprintln!("conest_updater: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let config = Config::from_args()?;
    if !config.staging_dir.is_dir() {
        return Err(format!(
            "staging directory does not exist: {}",
            config.staging_dir.display()
        ));
    }
    fs::create_dir_all(&config.bundle_dir)
        .map_err(|error| format!("could not prepare bundle directory: {error}"))?;

    let mut last_error = None;
    for _ in 0..MAX_ATTEMPTS {
        match sync_directories(&config.staging_dir, &config.bundle_dir) {
            Ok(()) => {
                launch_application(&config)?;
                return Ok(());
            }
            Err(error) => {
                last_error = Some(error);
                thread::sleep(RETRY_DELAY);
            }
        }
    }

    Err(format!(
        "could not apply update after {MAX_ATTEMPTS} attempts: {}",
        last_error.unwrap_or_else(|| "unknown error".to_owned())
    ))
}

struct Config {
    staging_dir: PathBuf,
    bundle_dir: PathBuf,
    app_binary: String,
}

impl Config {
    fn from_args() -> Result<Self, String> {
        let mut staging_dir = None;
        let mut bundle_dir = None;
        let mut app_binary = None;
        let mut args = env::args().skip(1).peekable();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--staging-dir" => staging_dir = Some(next_arg(&mut args, &arg)?),
                "--bundle-dir" => bundle_dir = Some(next_arg(&mut args, &arg)?),
                "--app-binary" => app_binary = Some(next_arg(&mut args, &arg)?),
                "--help" | "-h" => return Err(usage()),
                value => return Err(format!("unknown option: {value}\n\n{}", usage())),
            }
        }
        Ok(Self {
            staging_dir: PathBuf::from(
                staging_dir.ok_or_else(|| format!("missing --staging-dir\n\n{}", usage()))?,
            ),
            bundle_dir: PathBuf::from(
                bundle_dir.ok_or_else(|| format!("missing --bundle-dir\n\n{}", usage()))?,
            ),
            app_binary: app_binary.ok_or_else(|| format!("missing --app-binary\n\n{}", usage()))?,
        })
    }
}

fn usage() -> String {
    "usage: conest_updater --staging-dir <dir> --bundle-dir <dir> --app-binary <name>".to_owned()
}

fn next_arg(
    args: &mut std::iter::Peekable<impl Iterator<Item = String>>,
    option: &str,
) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("missing value for {option}\n\n{}", usage()))
}

fn sync_directories(source: &Path, destination: &Path) -> Result<(), String> {
    copy_entries(source, destination)?;
    remove_stale_entries(source, destination)?;
    Ok(())
}

fn copy_entries(source: &Path, destination: &Path) -> Result<(), String> {
    for entry in read_directory(source)? {
        let source_path = entry.path();
        let destination_path = destination.join(entry.file_name());
        let file_type = entry
            .file_type()
            .map_err(|error| format!("could not inspect {}: {error}", source_path.display()))?;
        if file_type.is_dir() {
            if destination_path.is_file() {
                fs::remove_file(&destination_path).map_err(|error| {
                    format!(
                        "could not remove file {} before creating directory: {error}",
                        destination_path.display()
                    )
                })?;
            }
            fs::create_dir_all(&destination_path).map_err(|error| {
                format!(
                    "could not create directory {}: {error}",
                    destination_path.display()
                )
            })?;
            copy_entries(&source_path, &destination_path)?;
        } else if file_type.is_file() {
            copy_file(&source_path, &destination_path)?;
        }
    }
    Ok(())
}

fn copy_file(source: &Path, destination: &Path) -> Result<(), String> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "could not create parent directory {}: {error}",
                parent.display()
            )
        })?;
    }
    if destination.is_dir() {
        fs::remove_dir_all(destination).map_err(|error| {
            format!(
                "could not remove directory {} before copying file: {error}",
                destination.display()
            )
        })?;
    }
    let temp_destination = destination.with_file_name(format!(
        ".{}.updating",
        destination
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_else(|| "conest".to_owned())
    ));
    if temp_destination.exists() {
        remove_path(&temp_destination)?;
    }
    fs::copy(source, &temp_destination).map_err(|error| {
        format!(
            "could not copy {} to {}: {error}",
            source.display(),
            temp_destination.display()
        )
    })?;
    preserve_permissions(source, &temp_destination)?;
    if destination.exists() {
        remove_path(destination)?;
    }
    fs::rename(&temp_destination, destination).map_err(|error| {
        format!(
            "could not move {} into place at {}: {error}",
            temp_destination.display(),
            destination.display()
        )
    })?;
    Ok(())
}

fn remove_stale_entries(source: &Path, destination: &Path) -> Result<(), String> {
    let source_entries = read_directory(source)?;
    let source_names = source_entries
        .iter()
        .map(|entry| entry.file_name())
        .collect::<HashSet<_>>();
    for entry in read_directory(destination)? {
        let destination_path = entry.path();
        let file_name = entry.file_name();
        if !source_names.contains(&file_name) {
            remove_path(&destination_path)?;
            continue;
        }
        let source_path = source.join(&file_name);
        let destination_type = entry.file_type().map_err(|error| {
            format!(
                "could not inspect destination {}: {error}",
                destination_path.display()
            )
        })?;
        let source_type = fs::metadata(&source_path)
            .map_err(|error| {
                format!(
                    "could not inspect source {}: {error}",
                    source_path.display()
                )
            })?
            .file_type();
        if source_type.is_dir() && destination_type.is_dir() {
            remove_stale_entries(&source_path, &destination_path)?;
        }
    }
    Ok(())
}

fn remove_path(path: &Path) -> Result<(), String> {
    if path.is_dir() {
        fs::remove_dir_all(path)
            .map_err(|error| format!("could not remove directory {}: {error}", path.display()))
    } else {
        fs::remove_file(path)
            .map_err(|error| format!("could not remove file {}: {error}", path.display()))
    }
}

fn read_directory(path: &Path) -> Result<Vec<fs::DirEntry>, String> {
    let mut entries = fs::read_dir(path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("could not enumerate {}: {error}", path.display()))?;
    entries.sort_by_key(|entry| entry.file_name());
    Ok(entries)
}

fn launch_application(config: &Config) -> Result<(), String> {
    let app_path = config.bundle_dir.join(&config.app_binary);
    Command::new(&app_path)
        .current_dir(&config.bundle_dir)
        .spawn()
        .map_err(|error| format!("could not relaunch {}: {error}", app_path.display()))?;
    Ok(())
}

fn preserve_permissions(source: &Path, destination: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        let mode = fs::metadata(source)
            .map_err(|error| {
                format!(
                    "could not inspect permissions for {}: {error}",
                    source.display()
                )
            })?
            .permissions()
            .mode();
        let permissions = fs::Permissions::from_mode(mode);
        fs::set_permissions(destination, permissions).map_err(|error| {
            format!(
                "could not preserve permissions from {} to {}: {error}",
                source.display(),
                destination.display()
            )
        })?;
    }
    Ok(())
}
