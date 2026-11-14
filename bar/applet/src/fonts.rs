//! The running desktop's fonts for libcosmic windows and panel applets: the font part of the
//! shared look.rs, for the Maprisma crates without look.rs (no colours, no corners). Shared
//! copy: the same file in every such crate (Maprisma Video Translator's captions use look.rs
//! itself); change it there and keep its functions identical to look.rs's (the rules: the
//! maprisma-layout skill).
//!
//! Fonts (Maprisma Theme's Font & effects sets them on all three): the interface family for all
//! text, the monospace one for code, logs and commands ([mono_font]). COSMIC: libcosmic's own
//! (CosmicTk). KDE: kdeglobals `[General] font` / `fixed`. Hyprland and others: gsettings
//! `font-name` / `monospace-font-name` (the Pango size dropped). Outside COSMIC the families go
//! into libcosmic's in-memory toolkit config (never its files), so `text::body`, the headings and
//! `cosmic::font::*` follow; [keep_fonts] at start and at the top of `view` / `view_window` puts
//! them back after libcosmic re-reads CosmicTk (it does at start and on every change of COSMIC's
//! config). The fonts are read again when they are 30 s old (at the next `view`, or [refresh]
//! from a periodic tick).
//!
//! The desktop as look.rs finds it: `MAPRISMA_DESKTOP=cosmic|kde|hyprland|other` overrides it;
//! `XDG_CURRENT_DESKTOP` decides; only without it the session's other marks do (desktop_in).

use std::path::{Path, PathBuf};
use std::sync::RwLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Desktop {
    Cosmic,
    Kde,
    Hyprland,
    Other,
}

pub fn desktop_from(forced: Option<&str>, current: &str) -> Desktop {
    match forced.map(str::to_ascii_lowercase).as_deref() {
        Some("cosmic") => return Desktop::Cosmic,
        Some("kde") => return Desktop::Kde,
        Some("hyprland") => return Desktop::Hyprland,
        Some("other") => return Desktop::Other,
        _ => {}
    }
    let names: Vec<String> = current.split(':').map(str::to_ascii_uppercase).collect();
    if names.iter().any(|n| n == "COSMIC") {
        Desktop::Cosmic
    } else if names.iter().any(|n| n == "KDE") {
        Desktop::Kde
    } else if names.iter().any(|n| n == "HYPRLAND") {
        Desktop::Hyprland
    } else {
        Desktop::Other
    }
}

/// The session's other marks, asked only when `XDG_CURRENT_DESKTOP` is unset or empty (a
/// service or wrapper that dropped it).
#[derive(Debug, Clone, Default)]
pub struct SessionHints {
    /// `XDG_SESSION_DESKTOP` and `DESKTOP_SESSION` joined with ':' (names or session-file paths).
    pub session: String,
    /// `HYPRLAND_INSTANCE_SIGNATURE` is set and that instance's socket exists ([hyprland_socket_in]).
    pub hyprland_socket: bool,
    /// Plasma's `KDE_FULL_SESSION` is "true".
    pub kde_full_session: bool,
}

/// The desktop from the session's name(s): `KDE`, `plasma`, `plasmawayland.desktop`, `COSMIC`,
/// `hyprland-uwsm` …; Other when none is known.
pub fn session_desktop(session: &str) -> Desktop {
    for name in session.split(':') {
        let name = name.rsplit('/').next().unwrap_or("").trim().trim_end_matches(".desktop").to_ascii_lowercase();
        if name == "cosmic" || name.starts_with("cosmic-") {
            return Desktop::Cosmic;
        } else if name == "kde" || name.starts_with("plasma") {
            return Desktop::Kde;
        } else if name.starts_with("hyprland") {
            return Desktop::Hyprland;
        }
    }
    Desktop::Other
}

/// MAPRISMA_DESKTOP (when it names a desktop), else XDG_CURRENT_DESKTOP, else the session's
/// other marks.
pub fn desktop_in(forced: Option<&str>, current: &str, hints: &SessionHints) -> Desktop {
    let forced_valid = forced
        .map(str::to_ascii_lowercase)
        .is_some_and(|f| matches!(f.as_str(), "cosmic" | "kde" | "hyprland" | "other"));
    if forced_valid || !current.trim().is_empty() {
        return desktop_from(forced, current);
    }
    match session_desktop(&hints.session) {
        Desktop::Other => {}
        found => return found,
    }
    if hints.hyprland_socket {
        Desktop::Hyprland
    } else if hints.kde_full_session {
        Desktop::Kde
    } else {
        Desktop::Other
    }
}

/// Whether Hyprland instance `signature` has its socket under `runtime_dir`
/// (`$XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock`). A signature that isn't a plain name is not.
pub fn hyprland_socket_in(runtime_dir: &Path, signature: &str) -> bool {
    let signature = signature.trim();
    !signature.is_empty()
        && signature.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
        && !signature.starts_with('.')
        && runtime_dir.join("hypr").join(signature).join(".socket.sock").exists()
}

pub fn desktop() -> Desktop {
    // Unit tests never read the session's files or ask hyprctl.
    if cfg!(test) {
        return Desktop::Other;
    }
    let var = |name: &str| std::env::var(name).unwrap_or_default();
    let forced = std::env::var("MAPRISMA_DESKTOP").ok();
    let current = var("XDG_CURRENT_DESKTOP");
    if !current.trim().is_empty() {
        // The usual case: no session marks, no file system.
        return desktop_from(forced.as_deref(), &current);
    }
    let runtime = var("XDG_RUNTIME_DIR");
    desktop_in(
        forced.as_deref(),
        &current,
        &SessionHints {
            session: format!("{}:{}", var("XDG_SESSION_DESKTOP"), var("DESKTOP_SESSION")),
            hyprland_socket: !runtime.is_empty()
                && hyprland_socket_in(Path::new(&runtime), &var("HYPRLAND_INSTANCE_SIGNATURE")),
            kde_full_session: var("KDE_FULL_SESSION").trim().eq_ignore_ascii_case("true"),
        },
    )
}

fn read_small(path: &Path, max: u64) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > max {
        return None;
    }
    std::fs::read(path).ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

fn xdg(var: &str, fallback: &str) -> PathBuf {
    match std::env::var_os(var).map(PathBuf::from) {
        Some(p) if p.is_absolute() => p,
        _ => home().join(fallback),
    }
}

fn ini(text: &str, group: &str, key: &str) -> Option<String> {
    let (mut current, mut found) = (None::<&str>, None);
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') && line.ends_with(']') {
            current = Some(&line[1..line.len() - 1]);
        } else if current == Some(group) {
            if let Some((k, v)) = line.split_once('=') {
                if k.trim() == key {
                    found = Some(v.trim().to_string());
                }
            }
        }
    }
    found
}

/// The desktop's (interface, monospace) font families; each None where libcosmic's is right
/// (COSMIC) or nothing is known.
pub type FontPair = (Option<String>, Option<String>);

/// A Pango font description without its size: "Noto Sans  10" → "Noto Sans", "Hack, 10.5" →
/// "Hack" (as Maprisma Manager's `pangoFamily`).
pub fn pango_family(font: &str) -> String {
    let font = font.trim();
    let number = font.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
    let size = &font[number.len()..];
    let is_size = !size.is_empty()
        && size.split('.').count() <= 2
        && size.split('.').all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()));
    if !is_size || !number.ends_with(char::is_whitespace) {
        return font.to_string();
    }
    let rest = number.trim_end();
    rest.strip_suffix(',').unwrap_or(rest).trim().to_string()
}

/// A family from `gsettings get` output ("'Noto Sans  10'\n"); None when it isn't a quoted string.
pub fn gsettings_family(out: &str) -> Option<String> {
    let out = out.trim();
    let inner = out.strip_prefix('\'')?.strip_suffix('\'')?;
    Some(pango_family(inner))
}

/// Plasma's interface and fixed families from kdeglobals (the first comma field of
/// `[General] font` / `fixed`).
pub fn kde_fonts(text: &str) -> FontPair {
    let family = |key: &str| ini(text, "General", key).and_then(|v| v.split(',').next().map(str::to_string));
    (family("font"), family("fixed"))
}

fn clean_family(family: Option<String>) -> Option<String> {
    let family = family?.trim().to_string();
    (!family.is_empty() && family.chars().count() <= 100 && !family.chars().any(char::is_control)).then_some(family)
}

/// The desktop's fonts from `kdeglobals` (KDE) or `gsettings(key)` (the raw output of `gsettings
/// get org.gnome.desktop.interface <key>`, Hyprland and others); none on COSMIC.
pub fn fonts_in(desktop: Desktop, kdeglobals: &Path, gsettings: impl Fn(&str) -> Option<String>) -> FontPair {
    let (ui, mono) = match desktop {
        Desktop::Cosmic => return (None, None),
        Desktop::Kde => read_small(kdeglobals, 1024 * 1024).map(|t| kde_fonts(&t)).unwrap_or_default(),
        Desktop::Hyprland | Desktop::Other => {
            let family = |key: &str| gsettings(key).as_deref().and_then(gsettings_family);
            (family("font-name"), family("monospace-font-name"))
        }
    };
    (clean_family(ui), clean_family(mono))
}

fn gsettings(key: &str) -> Option<String> {
    let out = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", key])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The running desktop's (interface, monospace) font families, read now; (None, None) on COSMIC
/// (libcosmic reads CosmicTk itself) and in unit tests.
pub fn desktop_fonts() -> FontPair {
    if cfg!(test) {
        return (None, None);
    }
    fonts_in(desktop(), &xdg("XDG_CONFIG_HOME", ".config").join("kdeglobals"), gsettings)
}

/// A family name for `iced::font::Family::Name` (kept for the process, each name once).
fn static_family(family: &str) -> &'static str {
    static NAMES: std::sync::Mutex<std::collections::BTreeSet<&'static str>> =
        std::sync::Mutex::new(std::collections::BTreeSet::new());
    let mut names = NAMES.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(name) = names.get(family) {
        return name;
    }
    let name: &'static str = family.to_string().leak();
    names.insert(name);
    name
}

/// `base` in `family` (weight, stretch and style stay `base`'s); `base` itself without one.
pub fn font_in(family: Option<&str>, base: cosmic::font::Font) -> cosmic::font::Font {
    match family {
        Some(f) => cosmic::font::Font { family: cosmic::iced::font::Family::Name(static_family(f)), ..base },
        None => base,
    }
}

/// The interface font for `cosmic::app::Settings::default_font`: the desktop's family outside
/// COSMIC, libcosmic's otherwise.
#[allow(dead_code)] // panel-only applets have no app Settings (keep_fonts sets theirs)
pub fn default_font() -> cosmic::font::Font {
    keep_fonts();
    with_state(|s| font_in(s.fonts.0.as_deref(), cosmic::font::default()))
}

/// The monospace font for code, logs and commands: the desktop's family outside COSMIC,
/// libcosmic's (`cosmic::font::mono()`) otherwise.
#[allow(dead_code)] // not every app shows monospace text
pub fn mono_font() -> cosmic::font::Font {
    with_state(|s| font_in(s.fonts.1.as_deref(), cosmic::font::mono()))
}

/// The desktop's families into libcosmic's in-memory toolkit config (outside COSMIC, where they
/// are known); nothing is written to disk. Cheap when they are in already: called at start and at
/// the top of every `view` / `view_window`.
pub fn keep_fonts() {
    let (ui, mono) = with_state(|s| s.fonts.clone());
    if ui.is_none() && mono.is_none() {
        return;
    }
    let differs = |tk: &cosmic::config::CosmicTk| {
        ui.as_ref().is_some_and(|f| tk.interface_font.family != *f)
            || mono.as_ref().is_some_and(|f| tk.monospace_font.family != *f)
    };
    if !cosmic::config::COSMIC_TK.read().map(|tk| differs(&tk)).unwrap_or(false) {
        return;
    }
    if let Ok(mut tk) = cosmic::config::COSMIC_TK.write() {
        if let Some(f) = &ui {
            tk.interface_font.family = f.clone();
        }
        if let Some(f) = &mono {
            tk.monospace_font.family = f.clone();
        }
    }
}

struct State {
    fonts: FontPair,
    read: std::time::Instant,
}

static STATE: RwLock<Option<State>> = RwLock::new(None);

/// How old the fonts may get before they are read again (gsettings is a process).
const REREAD: std::time::Duration = std::time::Duration::from_secs(30);

/// Reads the desktop's fonts again now and puts them into libcosmic; true when they changed.
pub fn reload() -> bool {
    let fresh = State { fonts: desktop_fonts(), read: std::time::Instant::now() };
    let Ok(mut state) = STATE.write() else { return false };
    let changed = state.as_ref().is_none_or(|s| s.fonts != fresh.fonts);
    *state = Some(fresh);
    drop(state);
    keep_fonts();
    changed
}

/// [reload] when the fonts are 30 s old or not read yet; true when they changed (for a periodic
/// tick; [keep_fonts] does the same on its own).
#[allow(dead_code)] // not every crate has a tick
pub fn refresh() -> bool {
    // The read lock ends with this statement: reload() takes the write lock.
    let due = STATE.read().ok().and_then(|s| s.as_ref().map(|s| s.read.elapsed() >= REREAD));
    due != Some(false) && reload()
}

fn with_state<T>(f: impl FnOnce(&State) -> T) -> T {
    let due = STATE.read().map(|s| s.as_ref().is_none_or(|s| s.read.elapsed() >= REREAD)).unwrap_or(true);
    if due {
        reload();
    }
    let state = STATE.read().expect("font state");
    f(state.as_ref().expect("font state loaded"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktops() {
        assert_eq!(desktop_from(None, "Hyprland"), Desktop::Hyprland);
        assert_eq!(desktop_from(None, "COSMIC"), Desktop::Cosmic);
        assert_eq!(desktop_from(None, "KDE"), Desktop::Kde);
        assert_eq!(desktop_from(None, "ubuntu:GNOME"), Desktop::Other);
        assert_eq!(desktop_from(Some("kde"), "Hyprland"), Desktop::Kde);
        assert_eq!(desktop_from(Some("bogus"), "COSMIC"), Desktop::Cosmic);
    }

    #[test]
    fn desktop_without_xdg_current_desktop() {
        let none = SessionHints::default();
        let hints = |s: &str, h: bool, k: bool| SessionHints { session: s.into(), hyprland_socket: h, kde_full_session: k };
        // XDG_CURRENT_DESKTOP set: the marks are not asked (a stale Hyprland socket included).
        assert_eq!(desktop_in(None, "KDE", &hints("", true, false)), Desktop::Kde);
        assert_eq!(desktop_in(None, "COSMIC", &hints("hyprland", true, false)), Desktop::Cosmic);
        assert_eq!(desktop_in(None, "ubuntu:GNOME", &hints("KDE", false, true)), Desktop::Other);
        // Unset or empty: the session's marks.
        assert_eq!(desktop_in(None, "", &none), Desktop::Other);
        assert_eq!(desktop_in(None, "", &hints("KDE:plasma", false, false)), Desktop::Kde);
        assert_eq!(desktop_in(None, " ", &hints(":/usr/share/wayland-sessions/plasmawayland.desktop", false, false)), Desktop::Kde);
        assert_eq!(desktop_in(None, "", &hints("hyprland:hyprland-uwsm", false, false)), Desktop::Hyprland);
        assert_eq!(desktop_in(None, "", &hints("COSMIC:cosmic", false, false)), Desktop::Cosmic);
        assert_eq!(desktop_in(None, "", &hints(":", true, false)), Desktop::Hyprland);
        assert_eq!(desktop_in(None, "", &hints(":", false, true)), Desktop::Kde);
        assert_eq!(desktop_in(None, "", &hints("gnome:gnome", false, false)), Desktop::Other);
        // MAPRISMA_DESKTOP still wins, "other" too; a bogus one is ignored.
        assert_eq!(desktop_in(Some("other"), "", &hints("KDE", true, true)), Desktop::Other);
        assert_eq!(desktop_in(Some("cosmic"), "", &hints("KDE", false, false)), Desktop::Cosmic);
        assert_eq!(desktop_in(Some("bogus"), "", &hints("", true, false)), Desktop::Hyprland);
        assert_eq!(desktop_in(Some("kde"), "Hyprland", &none), Desktop::Kde);
    }

    #[test]
    fn hyprland_only_with_its_socket() {
        let dir = std::env::temp_dir().join(format!("fonts-hypr-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("hypr/live_1")).unwrap();
        std::fs::write(dir.join("hypr/live_1/.socket.sock"), b"").unwrap();
        std::fs::create_dir_all(dir.join("hypr/stale_2")).unwrap();
        assert!(hyprland_socket_in(&dir, "live_1"));
        assert!(!hyprland_socket_in(&dir, "stale_2"), "signature left over, no socket");
        assert!(!hyprland_socket_in(&dir, "gone_3"));
        assert!(!hyprland_socket_in(&dir, ""));
        assert!(!hyprland_socket_in(&dir, "../hypr/live_1"));
        assert!(!hyprland_socket_in(&dir, ".."));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pango_sizes_dropped() {
        assert_eq!(pango_family("Noto Sans  10"), "Noto Sans");
        assert_eq!(pango_family("Hack, 10.5"), "Hack");
        assert_eq!(pango_family("Cantarell 11"), "Cantarell");
        assert_eq!(pango_family("  JetBrains Mono Bold 12 "), "JetBrains Mono Bold");
        assert_eq!(pango_family("Cantarell"), "Cantarell");
        assert_eq!(pango_family("Font10"), "Font10");
        assert_eq!(pango_family("Source Code Pro 3D"), "Source Code Pro 3D");
        assert_eq!(pango_family("Weird 1.2.3"), "Weird 1.2.3");
        assert_eq!(gsettings_family("'Noto Sans  10'\n"), Some("Noto Sans".into()));
        assert_eq!(gsettings_family("'Hack, 10.5'"), Some("Hack".into()));
        assert_eq!(gsettings_family("No such key \"font-name\""), None);
        assert_eq!(gsettings_family(""), None);
    }

    #[test]
    fn kde_font_families() {
        let text = "[General]\nfixed=Hack,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\n\
                    [WM]\nfont=Other,10\n";
        assert_eq!(kde_fonts(text), (Some("Noto Sans".into()), Some("Hack".into())));
        assert_eq!(kde_fonts("[WM]\nfont=Other,10\n"), (None, None));
    }

    #[test]
    fn fonts_per_desktop() {
        let dir = std::env::temp_dir().join(format!("fonts-fonts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let kdeglobals = dir.join("kdeglobals");
        std::fs::write(&kdeglobals, "[General]\nfont=Inter,10,-1\nfixed=Fira Code,9\n").unwrap();
        let gtk = |key: &str| match key {
            "font-name" => Some("'Noto Sans  10'\n".to_string()),
            "monospace-font-name" => Some("'Hack, 10.5'\n".to_string()),
            _ => None,
        };
        let asked = std::cell::Cell::new(false);
        let gtk_asked = |key: &str| {
            asked.set(true);
            gtk(key)
        };
        assert_eq!(fonts_in(Desktop::Cosmic, &kdeglobals, gtk_asked), (None, None));
        assert!(!asked.get(), "COSMIC: libcosmic reads its own fonts");
        assert_eq!(fonts_in(Desktop::Kde, &kdeglobals, gtk_asked), (Some("Inter".into()), Some("Fira Code".into())));
        assert!(!asked.get(), "KDE: kdeglobals, not gsettings");
        assert_eq!(fonts_in(Desktop::Kde, &dir.join("missing"), gtk), (None, None));
        assert_eq!(fonts_in(Desktop::Hyprland, &kdeglobals, gtk), (Some("Noto Sans".into()), Some("Hack".into())));
        assert_eq!(fonts_in(Desktop::Other, &kdeglobals, gtk), (Some("Noto Sans".into()), Some("Hack".into())));
        assert_eq!(fonts_in(Desktop::Hyprland, &kdeglobals, |_| None), (None, None));
        assert_eq!(fonts_in(Desktop::Hyprland, &kdeglobals, |_| Some("''".into())), (None, None));
        std::fs::write(&kdeglobals, "[General]\nfont= ,10\n").unwrap();
        assert_eq!(fonts_in(Desktop::Kde, &kdeglobals, gtk), (None, None));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fonts_take_the_family() {
        let base = cosmic::font::Font { weight: cosmic::iced::font::Weight::Bold, ..cosmic::font::Font::DEFAULT };
        let f = font_in(Some("Inter"), base);
        assert_eq!(f.family, cosmic::iced::font::Family::Name("Inter"));
        assert_eq!(f.weight, cosmic::iced::font::Weight::Bold);
        assert_eq!(font_in(None, base), base);
        assert!(std::ptr::eq(static_family("Inter"), static_family("Inter")));
        // Unit tests know no desktop: libcosmic's fonts stay.
        assert_eq!(desktop_fonts(), (None, None));
    }
}
