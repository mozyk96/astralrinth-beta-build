use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::{Command, ExitCode, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

fn now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    Command::new("date")
        .arg("+%Y-%m-%d %H:%M:%S %Z")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| format!("unix:{secs}"))
}

fn log(root: &Path, msg: &str) {
    let state = root.join("state");
    let _ = fs::create_dir_all(&state);
    let line = format!("[{}] {}\n", now(), msg);
    print!("{line}");
    let _ = std::io::stdout().flush();
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(state.join("publisher.log"))
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn print_help() {
    println!(
        r#"astralrinth-publisher — Orchestrator for AstralRinth Beta builds on CachyOS/Arch Linux

USAGE:
    astralrinth-publisher [OPTIONS]

OPTIONS:
    --root <PATH>         Path to astralrinth-beta-build repository root (default: current directory)
    --targets <LIST>, -t  Build targets: base (x86-64), v3 (x86-64-v3), v4 (x86-64-v4), or all
                          Comma- or space-separated list (default: x86-64 x86-64-v3 x86-64-v4)
    --force, -f           Force build and publish even if upstream commit is unchanged
    --status, -s          Show detailed status of upstream, local build, AUR, and caches
    --clean [TARGET]      Clean build cache (all, base, v3, v4, or source)
    --help, -h            Show this help message

EXAMPLES:
    astralrinth-publisher --root ~/astralrinth-beta-build
    astralrinth-publisher --targets "base,v3"
    astralrinth-publisher --status
    astralrinth-publisher --force
"#
    );
}

fn dir_size(path: &Path) -> String {
    if !path.exists() {
        return "none".to_string();
    }
    Command::new("du")
        .arg("-sh")
        .arg(path)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            let out = String::from_utf8_lossy(&o.stdout);
            out.split_whitespace()
                .next()
                .unwrap_or("unknown")
                .to_string()
        })
        .unwrap_or_else(|| "unknown".to_string())
}

fn check_status(root: &Path) -> ExitCode {
    println!("=== AstralRinth Beta Local Build Status ===");
    println!("Project root:       {}", root.display());

    let state_dir = root.join("state");
    let current_sha = fs::read_to_string(state_dir.join("upstream-commit.txt"))
        .unwrap_or_else(|_| "not recorded".to_string())
        .trim()
        .to_string();
    let current_tag = fs::read_to_string(state_dir.join("release-tag.txt"))
        .unwrap_or_else(|_| "not recorded".to_string())
        .trim()
        .to_string();

    println!("Last built commit:  {}", current_sha);
    println!("Last release tag:   {}", current_tag);

    // Upstream check
    let upstream_url = "https://git.xorison.dev/didirus/AstralRinth.git";
    let upstream_output = Command::new("git")
        .args(["ls-remote", upstream_url, "refs/heads/beta"])
        .output();
    let remote_sha = match upstream_output {
        Ok(out) if out.status.success() => {
            let s = String::from_utf8_lossy(&out.stdout);
            s.split_whitespace().next().unwrap_or("unknown").to_string()
        }
        _ => "unreachable".to_string(),
    };
    println!("Upstream beta HEAD: {}", remote_sha);

    let needs_update = remote_sha != "unreachable" && remote_sha != current_sha;
    println!(
        "Update pending:     {}",
        if needs_update { "YES" } else { "NO" }
    );

    // Host CPU ISA support
    let isa_output = Command::new("/usr/lib/ld-linux-x86-64.so.2")
        .arg("--help")
        .output();
    let (has_v3, has_v4) = match isa_output {
        Ok(out) => {
            let s = String::from_utf8_lossy(&out.stdout);
            (
                s.contains("x86-64-v3 (supported"),
                s.contains("x86-64-v4 (supported"),
            )
        }
        _ => (false, false),
    };
    println!(
        "Host CPU ISA:       x86-64 (supported), x86-64-v3 ({}), x86-64-v4 ({})",
        if has_v3 { "supported" } else { "unsupported" },
        if has_v4 { "supported" } else { "unsupported" },
    );

    // Caches status
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let cache_root = PathBuf::from(
        env::var("BUILD_CACHE_DIR")
            .unwrap_or_else(|_| format!("{home}/.cache/astralrinth-beta-build")),
    );
    println!("Cache directory:    {}", cache_root.display());
    println!(
        "  - Upstream src:   {}",
        dir_size(&cache_root.join("AstralRinth"))
    );
    println!(
        "  - Target x86-64:  {}",
        dir_size(&cache_root.join("cargo-target-x86-64"))
    );
    println!(
        "  - Target v3:      {}",
        dir_size(&cache_root.join("cargo-target-x86-64-v3"))
    );
    println!(
        "  - Target v4:      {}",
        dir_size(&cache_root.join("cargo-target-x86-64-v4"))
    );

    // AUR Key status
    let aur_key = PathBuf::from(&home).join(".ssh/astralrinth_beta_aur_ci_ed25519");
    let aur_known_hosts = PathBuf::from(&home).join(".ssh/astralrinth_beta_aur_known_hosts");
    let key_present = aur_key.is_file() && aur_known_hosts.is_file();
    println!(
        "AUR SSH key:        {} ({})",
        if key_present { "Present" } else { "Missing" },
        aur_key.display()
    );

    // AUR published version check
    let aur_rpc = Command::new("curl")
        .args([
            "-fsSL",
            "-G",
            "--data-urlencode",
            "arg[]=astralrinth-beta-bin",
            "https://aur.archlinux.org/rpc/v5/info",
        ])
        .output();
    let aur_version = match aur_rpc {
        Ok(out) if out.status.success() => {
            let s = String::from_utf8_lossy(&out.stdout);
            Command::new("jq")
                .args(["-r", ".results[0].Version // \"not published\""])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .and_then(|mut child| {
                    if let Some(mut stdin) = child.stdin.take() {
                        let _ = stdin.write_all(s.as_bytes());
                    }
                    child.wait_with_output()
                })
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "parse error".to_string())
        }
        _ => "unreachable".to_string(),
    };
    println!("AUR published ver:  {}", aur_version);

    ExitCode::SUCCESS
}

fn clean_cache(target: Option<&str>) -> ExitCode {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let cache_root = PathBuf::from(
        env::var("BUILD_CACHE_DIR")
            .unwrap_or_else(|_| format!("{home}/.cache/astralrinth-beta-build")),
    );

    if !cache_root.exists() {
        println!("Cache directory {} does not exist.", cache_root.display());
        return ExitCode::SUCCESS;
    }

    match target {
        None | Some("all") => {
            println!("Cleaning entire build cache: {}", cache_root.display());
            let _ = fs::remove_dir_all(&cache_root);
            println!("Cache cleaned.");
        }
        Some("base") | Some("x86-64") => {
            let dir = cache_root.join("cargo-target-x86-64");
            println!("Removing: {}", dir.display());
            let _ = fs::remove_dir_all(&dir);
        }
        Some("v3") | Some("x86-64-v3") => {
            let dir = cache_root.join("cargo-target-x86-64-v3");
            println!("Removing: {}", dir.display());
            let _ = fs::remove_dir_all(&dir);
        }
        Some("v4") | Some("x86-64-v4") => {
            let dir = cache_root.join("cargo-target-x86-64-v4");
            println!("Removing: {}", dir.display());
            let _ = fs::remove_dir_all(&dir);
        }
        Some("source") | Some("src") => {
            let dir = cache_root.join("AstralRinth");
            println!("Removing source checkout: {}", dir.display());
            let _ = fs::remove_dir_all(&dir);
        }
        Some(other) => {
            eprintln!("Unknown clean target: {other}. Use all, base, v3, v4, or source.");
            return ExitCode::from(2);
        }
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let mut root: Option<PathBuf> = None;
    let mut force = false;
    let mut targets: Option<String> = None;
    let mut status_mode = false;
    let mut clean_target: Option<String> = None;
    let mut is_clean_command = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--force" | "-f" => force = true,
            "--targets" | "-t" => targets = args.next(),
            "--status" | "-s" => status_mode = true,
            "--clean" => {
                is_clean_command = true;
                clean_target = args.next();
            }
            "--help" | "-h" => {
                print_help();
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("Unknown argument: {other}\nRun --help for usage.");
                return ExitCode::from(2);
            }
        }
    }

    if is_clean_command {
        return clean_cache(clean_target.as_deref());
    }

    let root = match root {
        Some(p) => p,
        None => {
            let current = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            if current.join("scripts/check-and-publish-local.sh").is_file() {
                current
            } else if let Ok(home) = env::var("HOME") {
                let candidate = PathBuf::from(home).join("astralrinth-beta-build");
                if candidate
                    .join("scripts/check-and-publish-local.sh")
                    .is_file()
                {
                    candidate
                } else {
                    eprintln!("Missing --root PATH (could not auto-detect astralrinth-beta-build directory).");
                    return ExitCode::from(2);
                }
            } else {
                eprintln!("Missing --root PATH");
                return ExitCode::from(2);
            }
        }
    };

    let root = match fs::canonicalize(&root) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Invalid project root ({}): {e}", root.display());
            return ExitCode::from(2);
        }
    };

    if !root.join("scripts/check-and-publish-local.sh").is_file() {
        eprintln!(
            "Missing scripts/check-and-publish-local.sh in {}",
            root.display()
        );
        return ExitCode::from(2);
    }

    if status_mode {
        return check_status(&root);
    }

    log(&root, "AstralRinth check started.");

    let mut cmd = Command::new("bash");
    cmd.arg(root.join("scripts/check-and-publish-local.sh"));
    cmd.current_dir(&root)
        .env("ASTRALRINTH_PROJECT_ROOT", &root)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    if force {
        cmd.env("ASTRALRINTH_FORCE_CHECK", "1");
    }
    if let Some(t) = targets {
        cmd.env("ASTRALRINTH_TARGETS", t.replace(',', " "));
    }

    let status = match cmd.status() {
        Ok(s) => s,
        Err(e) => {
            log(&root, &format!("Could not launch checker: {e}"));
            return ExitCode::FAILURE;
        }
    };

    if status.success() {
        log(&root, "AstralRinth check completed successfully.");
        ExitCode::SUCCESS
    } else {
        log(
            &root,
            &format!("AstralRinth check finished with status: {status}"),
        );
        ExitCode::FAILURE
    }
}
