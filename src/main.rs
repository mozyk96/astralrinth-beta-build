use std::{env, fs::{self, OpenOptions}, io::Write, path::{Path, PathBuf}, process::{Command, ExitCode, Stdio}, time::{SystemTime, UNIX_EPOCH}};

fn now() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
    // Use system date for readable local timestamps; Unix time remains in the log if date is absent.
    Command::new("date").arg("+%Y-%m-%d %H:%M:%S %Z").output().ok()
        .filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| format!("unix:{secs}"))
}
fn log(root: &Path, msg: &str) {
    let state = root.join("state");
    let _ = fs::create_dir_all(&state);
    let line = format!("[{}] {}\n", now(), msg);
    print!("{line}"); let _ = std::io::stdout().flush();
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(state.join("publisher.log")) { let _ = f.write_all(line.as_bytes()); }
}
fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let mut root: Option<PathBuf> = None;
    let mut force = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--force" => force = true,
            "--help" | "-h" => { println!("astralrinth-publisher --root PATH [--force]\nChecks upstream, builds only when needed, and publishes to GitHub Releases/AUR."); return ExitCode::SUCCESS; },
            other => { eprintln!("Unknown argument: {other}"); return ExitCode::from(2); }
        }
    }
    let root = match root { Some(p) => p, None => { eprintln!("Missing --root PATH"); return ExitCode::from(2); } };
    let root = match fs::canonicalize(&root) { Ok(p) => p, Err(e) => { eprintln!("Invalid project root: {e}"); return ExitCode::from(2); } };
    if !root.join("scripts/check-and-publish-local.sh").is_file() { eprintln!("Missing scripts/check-and-publish-local.sh in {}", root.display()); return ExitCode::from(2); }
    log(&root, "Daily check started.");
    let mut cmd = Command::new("bash");
    cmd.arg(root.join("scripts/check-and-publish-local.sh"));
    cmd.current_dir(&root).env("ASTRALRINTH_PROJECT_ROOT", &root)
       .stdin(Stdio::null()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
    if force { cmd.env("ASTRALRINTH_FORCE_CHECK", "1"); }
    let status = match cmd.status() { Ok(s) => s, Err(e) => { log(&root, &format!("Could not launch checker: {e}")); return ExitCode::FAILURE; } };
    if status.success() { log(&root, "Daily check completed successfully."); ExitCode::SUCCESS }
    else { log(&root, &format!("Daily check failed with status: {status}")); ExitCode::FAILURE }
}
