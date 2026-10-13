//! The files that make a screen's desktop: the openbox theme, rc and menu, the font configuration, and the
//! small scripts that start Chrome so that it works on a server. Everything is written into the screen's own
//! folder (`<screens>/<workspace>/desktop`), never into a system folder, and needs no root.

use super::paint::PANEL_HEIGHT;
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// Name of the openbox theme Bandito writes.
pub const THEME_NAME: &str = "Bandito";
/// The key that opens the root menu from the dock's mark (`xdotool key super+space`).
pub const MENU_KEY: &str = "super+space";

const ONEST_TTF: &[u8] = include_bytes!("../../assets/desktop/Onest.ttf");
const MONO_TTF: &[u8] = include_bytes!("../../assets/desktop/JetBrainsMono.ttf");
const ONEST_OFL: &[u8] = include_bytes!("../../assets/desktop/Onest-OFL.txt");
const MONO_OFL: &[u8] = include_bytes!("../../assets/desktop/JetBrainsMono-OFL.txt");

/// What a launcher on the dock and in the menu opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LauncherKind {
    Browser,
    Terminal,
    Files,
}

impl LauncherKind {
    /// The words on the dock and in the menu.
    pub fn label(self) -> &'static str {
        match self {
            Self::Browser => "Browser",
            Self::Terminal => "Terminal",
            Self::Files => "Files",
        }
    }
}

/// A program the dock and the menu can start. Only programs that exist on the server are listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Launcher {
    pub kind: LauncherKind,
    pub argv: Vec<String>,
}

const TERMINALS: [&str; 7] = [
    "xfce4-terminal",
    "gnome-terminal",
    "konsole",
    "lxterminal",
    "mate-terminal",
    "xterm",
    "x-terminal-emulator",
];
const FILE_MANAGERS: [&str; 7] = ["thunar", "pcmanfm", "pcmanfm-qt", "nautilus", "dolphin", "nemo", "caja"];

/// The launchers this server can offer: the first browser, terminal and file manager found on `path`.
/// A browser is started through the screen's own wrapper in `bin_dir` (see [`browser_wrapper`]).
pub fn detect_launchers(path: &OsStr, bin_dir: &Path) -> Vec<Launcher> {
    let mut found = Vec::new();
    if let Some(name) = crate::setup::BROWSERS
        .iter()
        .find(|name| crate::setup::which(name, path).is_some())
    {
        found.push(Launcher {
            kind: LauncherKind::Browser,
            argv: vec![bin_dir.join(name).display().to_string()],
        });
    }
    for (kind, names) in [
        (LauncherKind::Terminal, &TERMINALS[..]),
        (LauncherKind::Files, &FILE_MANAGERS[..]),
    ] {
        if let Some(program) = names.iter().find_map(|name| crate::setup::which(name, path)) {
            found.push(Launcher {
                kind,
                argv: vec![program.display().to_string()],
            });
        }
    }
    found
}

/// Escapes text for an XML element or attribute.
pub fn xml_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

/// Quotes one word for `sh`: inside single quotes, with a quote written as `'\''`.
pub fn shell_quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', "'\\''"))
}

/// `argv` as one command line for openbox's `Execute`.
pub fn command_line(argv: &[String]) -> String {
    argv.iter().map(|w| shell_quote(w)).collect::<Vec<_>>().join(" ")
}

/// About how tall the root menu is: a row of its text and padding is 22 pixels, a separator 12, the border 2. Slightly
/// more than it is, so the menu clears the dock.
fn menu_height(launchers: usize) -> u32 {
    let rows = launchers as u32 + 2;
    rows * 24 + if launchers > 0 { 12 } else { 0 } + 4
}

/// openbox's menu: the launchers that exist, the windows, and the desktop.
pub fn menu_xml(launchers: &[Launcher]) -> String {
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<openbox_menu xmlns=\"http://openbox.org/\">\n<menu id=\"root-menu\" label=\"Bandito\">\n",
    );
    for launcher in launchers {
        out.push_str(&format!(
            "  <item label=\"{}\">\n    <action name=\"Execute\"><command>{}</command></action>\n  </item>\n",
            launcher.kind.label(),
            xml_escape(&command_line(&launcher.argv)),
        ));
    }
    if !launchers.is_empty() {
        out.push_str("  <separator />\n");
    }
    out.push_str(
        "  <menu id=\"client-list-combined-menu\" />\n  <item label=\"Show desktop\">\n    <action name=\"ToggleShowDesktop\" />\n  </item>\n</menu>\n</openbox_menu>\n",
    );
    out
}

/// openbox's configuration: focus, placement, keys and mouse as a desktop expects, the Bandito theme, our menu.
/// `height` is the screen's height and `launchers` the number of launchers in the menu: together they place the menu
/// the dock's mark opens, just above the dock (a menu at a given place is not moved back onto the screen).
pub fn rc_xml(menu_file: &Path, height: u32, launchers: usize) -> String {
    let menu_y = height.saturating_sub(PANEL_HEIGHT + 6 + menu_height(launchers));
    let font = |place: &str, size: u32, weight: &str| {
        format!(
            "    <font place=\"{place}\"><name>Onest</name><size>{size}</size><weight>{weight}</weight><slant>Normal</slant></font>\n"
        )
    };
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<openbox_config xmlns=\"http://openbox.org/3.4/rc\">\n",
    );
    out.push_str(
        "  <resistance><strength>12</strength><screen_edge_strength>20</screen_edge_strength></resistance>\n\
         \x20 <focus><focusNew>yes</focusNew><followMouse>no</followMouse><focusLast>yes</focusLast><underMouse>no</underMouse><focusDelay>200</focusDelay><raiseOnFocus>no</raiseOnFocus></focus>\n\
         \x20 <placement><policy>Smart</policy><center>yes</center><monitor>Primary</monitor><primaryMonitor>1</primaryMonitor></placement>\n",
    );
    out.push_str(&format!(
        "  <theme>\n    <name>{THEME_NAME}</name>\n    <titleLayout>NLIMC</titleLayout>\n    <keepBorder>yes</keepBorder>\n    <animateIconify>yes</animateIconify>\n"
    ));
    out.push_str(&font("ActiveWindow", 10, "Bold"));
    out.push_str(&font("InactiveWindow", 10, "Normal"));
    out.push_str(&font("MenuHeader", 10, "Bold"));
    out.push_str(&font("MenuItem", 11, "Normal"));
    out.push_str(&font("ActiveOnScreenDisplay", 10, "Bold"));
    out.push_str(&font("InactiveOnScreenDisplay", 10, "Normal"));
    out.push_str("  </theme>\n");
    out.push_str(
        "  <desktops><number>1</number><firstdesk>1</firstdesk><names><name>Desktop</name></names><popupTime>0</popupTime></desktops>\n\
         \x20 <resize><drawContents>yes</drawContents><popupShow>Nonpixel</popupShow><popupPosition>Center</popupPosition></resize>\n\
         \x20 <margins><top>0</top><bottom>0</bottom><left>0</left><right>0</right></margins>\n",
    );
    out.push_str(&format!(
        "  <keyboard>\n\
         \x20   <chainQuitKey>C-g</chainQuitKey>\n\
         \x20   <keybind key=\"A-F4\"><action name=\"Close\" /></keybind>\n\
         \x20   <keybind key=\"A-Tab\"><action name=\"NextWindow\"><finalactions><action name=\"Focus\" /><action name=\"Raise\" /><action name=\"Unshade\" /></finalactions></action></keybind>\n\
         \x20   <keybind key=\"A-S-Tab\"><action name=\"PreviousWindow\"><finalactions><action name=\"Focus\" /><action name=\"Raise\" /><action name=\"Unshade\" /></finalactions></action></keybind>\n\
         \x20   <keybind key=\"W-d\"><action name=\"ToggleShowDesktop\" /></keybind>\n\
         \x20   <keybind key=\"W-Up\"><action name=\"ToggleMaximize\" /></keybind>\n\
         \x20   <keybind key=\"W-space\"><action name=\"ShowMenu\"><menu>root-menu</menu><position><x>8</x><y>{menu_y}</y></position></action></keybind>\n\
         \x20 </keyboard>\n"
    ));
    out.push_str(
        "  <mouse>\n\
         \x20   <dragThreshold>3</dragThreshold><doubleClickTime>400</doubleClickTime><screenEdgeWarpTime>0</screenEdgeWarpTime>\n\
         \x20   <context name=\"Frame\">\n\
         \x20     <mousebind button=\"A-Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind>\n\
         \x20     <mousebind button=\"A-Left\" action=\"Drag\"><action name=\"Move\" /></mousebind>\n\
         \x20     <mousebind button=\"A-Right\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /><action name=\"Unshade\" /></mousebind>\n\
         \x20     <mousebind button=\"A-Right\" action=\"Drag\"><action name=\"Resize\" /></mousebind>\n\
         \x20   </context>\n\
         \x20   <context name=\"Titlebar\">\n\
         \x20     <mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind>\n\
         \x20     <mousebind button=\"Left\" action=\"Drag\"><action name=\"Move\" /></mousebind>\n\
         \x20     <mousebind button=\"Left\" action=\"DoubleClick\"><action name=\"ToggleMaximize\" /></mousebind>\n\
         \x20     <mousebind button=\"Right\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /><action name=\"ShowMenu\"><menu>client-menu</menu></action></mousebind>\n\
         \x20   </context>\n\
         \x20   <context name=\"Top\"><mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind><mousebind button=\"Left\" action=\"Drag\"><action name=\"Resize\"><edge>top</edge></action></mousebind></context>\n\
         \x20   <context name=\"Bottom\"><mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind><mousebind button=\"Left\" action=\"Drag\"><action name=\"Resize\"><edge>bottom</edge></action></mousebind></context>\n\
         \x20   <context name=\"Left\"><mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind><mousebind button=\"Left\" action=\"Drag\"><action name=\"Resize\"><edge>left</edge></action></mousebind></context>\n\
         \x20   <context name=\"Right\"><mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind><mousebind button=\"Left\" action=\"Drag\"><action name=\"Resize\"><edge>right</edge></action></mousebind></context>\n\
         \x20   <context name=\"TLCorner BLCorner TRCorner BRCorner\"><mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind><mousebind button=\"Left\" action=\"Drag\"><action name=\"Resize\" /></mousebind></context>\n\
         \x20   <context name=\"Client\">\n\
         \x20     <mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind>\n\
         \x20     <mousebind button=\"Middle\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind>\n\
         \x20     <mousebind button=\"Right\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /></mousebind>\n\
         \x20   </context>\n\
         \x20   <context name=\"Icon\"><mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /><action name=\"Raise\" /><action name=\"ShowMenu\"><menu>client-menu</menu></action></mousebind></context>\n\
         \x20   <context name=\"Iconify\"><mousebind button=\"Left\" action=\"Click\"><action name=\"Iconify\" /></mousebind></context>\n\
         \x20   <context name=\"Maximize\"><mousebind button=\"Left\" action=\"Click\"><action name=\"ToggleMaximize\" /></mousebind></context>\n\
         \x20   <context name=\"Close\"><mousebind button=\"Left\" action=\"Click\"><action name=\"Close\" /></mousebind></context>\n\
         \x20   <context name=\"Desktop\">\n\
         \x20     <mousebind button=\"Left\" action=\"Press\"><action name=\"Focus\" /></mousebind>\n\
         \x20     <mousebind button=\"Right\" action=\"Press\"><action name=\"ShowMenu\"><menu>root-menu</menu></action></mousebind>\n\
         \x20     <mousebind button=\"Middle\" action=\"Press\"><action name=\"ShowMenu\"><menu>client-list-combined-menu</menu></action></mousebind>\n\
         \x20   </context>\n\
         \x20 </mouse>\n",
    );
    out.push_str(&format!(
        "  <menu><file>{}</file><hideDelay>200</hideDelay><middle>no</middle><submenuShowDelay>100</submenuShowDelay><submenuHideDelay>400</submenuHideDelay><showIcons>no</showIcons><manageDesktops>no</manageDesktops></menu>\n  <applications />\n</openbox_config>\n",
        xml_escape(&menu_file.display().to_string()),
    ));
    out
}

/// The openbox theme in the colors of `brand/tokens/tokens.json` (dark): `surface1/2/3` for frames and menus,
/// `text` / `text2` / `text3` for labels, hairlines as the text color mixed into the ground.
pub fn themerc() -> String {
    "! Bandito theme for openbox: the brand's warm dark. Colors are tokens from brand/tokens/tokens.json.\n\
     *.font: shadow=n\n\
     border.width: 1\n\
     padding.width: 12\n\
     padding.height: 8\n\
     window.handle.width: 0\n\
     window.client.padding.width: 0\n\
     menu.overlap: 4\n\
     *.justify: left\n\
     menu.title.text.justify: left\n\
     osd.border.width: 1\n\
     window.active.border.color: #3A352F\n\
     window.inactive.border.color: #26221E\n\
     window.active.title.separator.color: #221E1A\n\
     window.inactive.title.separator.color: #1A1714\n\
     window.active.title.bg: Flat Solid\n\
     window.active.title.bg.color: #221E1A\n\
     window.inactive.title.bg: Flat Solid\n\
     window.inactive.title.bg.color: #1A1714\n\
     window.active.label.bg: Parentrelative\n\
     window.inactive.label.bg: Parentrelative\n\
     window.active.label.text.color: #F3EBDD\n\
     window.inactive.label.text.color: #867C6D\n\
     window.active.button.*.bg: Flat Solid\n\
     window.active.button.*.bg.color: #221E1A\n\
     window.active.button.*.image.color: #BDB2A0\n\
     window.active.button.hover.bg.color: #2C2722\n\
     window.active.button.hover.image.color: #F3EBDD\n\
     window.active.button.pressed.bg.color: #38332D\n\
     window.active.button.pressed.image.color: #F3EBDD\n\
     window.active.button.disabled.image.color: #867C6D\n\
     window.inactive.button.*.bg: Flat Solid\n\
     window.inactive.button.*.bg.color: #1A1714\n\
     window.inactive.button.*.image.color: #867C6D\n\
     window.*.handle.bg: Flat Solid\n\
     window.*.handle.bg.color: #1A1714\n\
     window.*.grip.bg: Flat Solid\n\
     window.*.grip.bg.color: #1A1714\n\
     menu.border.width: 1\n\
     menu.border.color: #3A352F\n\
     menu.title.bg: Flat Solid\n\
     menu.title.bg.color: #221E1A\n\
     menu.title.text.color: #BDB2A0\n\
     menu.items.bg: Flat Solid\n\
     menu.items.bg.color: #1A1714\n\
     menu.items.text.color: #F3EBDD\n\
     menu.items.disabled.text.color: #867C6D\n\
     menu.items.active.bg: Flat Solid\n\
     menu.items.active.bg.color: #2C2722\n\
     menu.items.active.text.color: #F3EBDD\n\
     menu.separator.width: 1\n\
     menu.separator.padding.width: 0\n\
     menu.separator.padding.height: 5\n\
     menu.separator.color: #38332D\n\
     osd.border.color: #3A352F\n\
     osd.bg: Flat Solid\n\
     osd.bg.color: #1A1714\n\
     osd.active.label.bg: Parentrelative\n\
     osd.active.label.text.color: #F3EBDD\n\
     osd.inactive.label.bg: Parentrelative\n\
     osd.inactive.label.text.color: #867C6D\n\
     osd.hilight.bg: Flat Solid\n\
     osd.hilight.bg.color: #F3EBDD\n\
     osd.unhilight.bg: Flat Solid\n\
     osd.unhilight.bg.color: #38332D\n"
        .to_string()
}

/// fontconfig: the system's fonts and the ones in `fonts_dir` (Onest and JetBrains Mono), with the cache under
/// `cache_dir`. Programs on the screen read it through `FONTCONFIG_FILE`.
pub fn fonts_conf(fonts_dir: &Path, cache_dir: &Path) -> String {
    format!(
        "<?xml version=\"1.0\"?>\n<!DOCTYPE fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\">\n<fontconfig>\n  <include ignore_missing=\"yes\">/etc/fonts/fonts.conf</include>\n  <dir>{}</dir>\n  <cachedir>{}</cachedir>\n</fontconfig>\n",
        xml_escape(&fonts_dir.display().to_string()),
        xml_escape(&cache_dir.display().to_string()),
    )
}

/// A script that starts the browser `name` with the flags a server needs. Chrome asks the desktop keyring for the
/// key that encrypts its cookies; on a server nobody can unlock that keyring (the prompt waits for a person), and
/// every page then waits for ever and ends in ERR_TIMED_OUT, even `127.0.0.1`. `--password-store=basic` skips it.
/// The script finds the real program on the rest of `PATH`.
pub fn browser_wrapper() -> String {
    "#!/bin/sh\n\
     # Written by Bandito for this screen. Chrome waits for a desktop keyring that no one can unlock on a server\n\
     # (every page then ends in ERR_TIMED_OUT). --password-store=basic does not use the keyring.\n\
     me=$(basename \"$0\")\n\
     here=$(cd \"$(dirname \"$0\")\" && pwd)\n\
     old=$IFS\n\
     IFS=:\n\
     set -f\n\
     for dir in $PATH; do\n\
     \x20 [ -n \"$dir\" ] || continue\n\
     \x20 [ \"$dir/$me\" -ef \"$here/$me\" ] && continue\n\
     \x20 if [ -x \"$dir/$me\" ]; then\n\
     \x20   IFS=$old\n\
     \x20   exec \"$dir/$me\" --password-store=basic --ozone-platform=x11 --no-first-run --no-default-browser-check \"$@\"\n\
     \x20 fi\n\
     done\n\
     IFS=$old\n\
     echo \"$me: not found\" >&2\n\
     exit 127\n"
        .to_string()
}

/// The first of the usual dark cursor themes that is installed under `icons_root`.
pub fn cursor_theme(icons_root: &Path) -> Option<&'static str> {
    ["Adwaita", "DMZ-White", "Yaru", "Breeze_Snow", "breeze_cursors"]
        .into_iter()
        .find(|name| icons_root.join(name).join("cursors").is_dir())
}

/// What `prepare` made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prepared {
    /// The openbox configuration to start it with.
    pub rc_file: PathBuf,
    pub launchers: Vec<Launcher>,
    /// Added to the environment of every program on the screen (and of openbox).
    pub env: Vec<(String, String)>,
}

fn write_file(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    std::fs::write(path, bytes)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

/// Writes the desktop's files under `dir` (the screen's `desktop` folder) and returns what to start openbox with.
/// `path` is the server's `PATH` (the programs to offer are looked up there), `icons_root` is `/usr/share/icons`.
/// Files that were there are replaced, so an update of Bandito reaches a screen at its next start.
pub fn prepare(dir: &Path, path: &OsStr, icons_root: &Path, height: u32) -> io::Result<Prepared> {
    let bin = dir.join("bin");
    let fonts = dir.join("fonts");
    let theme_root = dir.join("share").join("themes").join(THEME_NAME).join("openbox-3");
    let menu_file = dir.join("menu.xml");
    let launchers = detect_launchers(path, &bin);

    write_file(&theme_root.join("themerc"), themerc().as_bytes(), 0o600)?;
    write_file(&menu_file, menu_xml(&launchers).as_bytes(), 0o600)?;
    let rc_file = dir.join("rc.xml");
    write_file(&rc_file, rc_xml(&menu_file, height, launchers.len()).as_bytes(), 0o600)?;
    write_file(&fonts.join("Onest.ttf"), ONEST_TTF, 0o600)?;
    write_file(&fonts.join("Onest-OFL.txt"), ONEST_OFL, 0o600)?;
    write_file(&fonts.join("JetBrainsMono.ttf"), MONO_TTF, 0o600)?;
    write_file(&fonts.join("JetBrainsMono-OFL.txt"), MONO_OFL, 0o600)?;
    let fonts_file = dir.join("fonts.conf");
    write_file(
        &fonts_file,
        fonts_conf(&fonts, &dir.join("font-cache")).as_bytes(),
        0o600,
    )?;
    for name in crate::setup::BROWSERS {
        write_file(&bin.join(name), browser_wrapper().as_bytes(), 0o700)?;
    }

    let mut env = vec![
        ("FONTCONFIG_FILE".to_string(), fonts_file.display().to_string()),
        (
            "PATH".to_string(),
            prepend_path(&bin, path).to_string_lossy().into_owned(),
        ),
        ("GTK_THEME".to_string(), "Adwaita:dark".to_string()),
        ("XCURSOR_SIZE".to_string(), "24".to_string()),
        // Programs open on this X screen, never on a Wayland desktop that the server may also have (WSLg on Windows
        // answers on `wayland-0`, and GTK tries it first). A made-up Wayland name cannot be connected to.
        ("GDK_BACKEND".to_string(), "x11".to_string()),
        ("QT_QPA_PLATFORM".to_string(), "xcb".to_string()),
        ("SDL_VIDEODRIVER".to_string(), "x11".to_string()),
        ("CLUTTER_BACKEND".to_string(), "x11".to_string()),
        ("MOZ_ENABLE_WAYLAND".to_string(), "0".to_string()),
        ("XDG_SESSION_TYPE".to_string(), "x11".to_string()),
        ("WAYLAND_DISPLAY".to_string(), "bandito-no-wayland".to_string()),
        (
            "XDG_DATA_DIRS".to_string(),
            prepend_data_dir(&dir.join("share"), std::env::var_os("XDG_DATA_DIRS"))
                .to_string_lossy()
                .into_owned(),
        ),
    ];
    if let Some(theme) = cursor_theme(icons_root) {
        env.push(("XCURSOR_THEME".to_string(), theme.to_string()));
    }
    if launchers.iter().any(|l| l.kind == LauncherKind::Browser) {
        // `xdg-open` and programs that open links use this one.
        if let Some(browser) = launchers.iter().find(|l| l.kind == LauncherKind::Browser) {
            env.push(("BROWSER".to_string(), browser.argv[0].clone()));
        }
    }
    Ok(Prepared {
        rc_file,
        launchers,
        env,
    })
}

/// `dir` first, then `path`.
fn prepend_path(dir: &Path, path: &OsStr) -> OsString {
    let mut parts = vec![dir.to_path_buf()];
    parts.extend(std::env::split_paths(path));
    std::env::join_paths(parts).unwrap_or_else(|_| path.to_os_string())
}

/// `dir`, then the data folders already set, or the standard two.
fn prepend_data_dir(dir: &Path, current: Option<OsString>) -> OsString {
    let rest = current
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| OsString::from("/usr/local/share:/usr/share"));
    let mut parts = vec![dir.to_path_buf()];
    parts.extend(std::env::split_paths(&rest));
    std::env::join_paths(parts).unwrap_or(rest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn fake_bin(dir: &Path, names: &[&str]) {
        for name in names {
            let file = dir.join(name);
            std::fs::write(&file, "#!/bin/sh\nexit 0\n").unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    #[test]
    fn launchers_are_only_what_the_server_has() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let none = detect_launchers(bin.as_os_str(), &tmp.path().join("own"));
        assert!(none.is_empty(), "nothing installed, nothing offered: {none:?}");

        fake_bin(&bin, &["chromium", "xterm", "thunar", "pcmanfm"]);
        let own = tmp.path().join("own");
        let found = detect_launchers(bin.as_os_str(), &own);
        let kinds: Vec<LauncherKind> = found.iter().map(|l| l.kind).collect();
        assert_eq!(
            kinds,
            [LauncherKind::Browser, LauncherKind::Terminal, LauncherKind::Files]
        );
        assert_eq!(
            found[0].argv,
            vec![own.join("chromium").display().to_string()],
            "the browser starts through the screen's wrapper"
        );
        assert!(
            found[2].argv[0].ends_with("thunar"),
            "the first file manager in the list wins"
        );
    }

    #[test]
    fn only_the_programs_found_get_a_launcher() {
        let tmp = tempfile::tempdir().unwrap();
        fake_bin(tmp.path(), &["xfce4-terminal"]);
        let found = detect_launchers(tmp.path().as_os_str(), &tmp.path().join("own"));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, LauncherKind::Terminal);
    }

    #[test]
    fn menu_quotes_commands_and_escapes_xml() {
        let launchers = vec![Launcher {
            kind: LauncherKind::Files,
            argv: vec!["/opt/it's <odd> & dir/thunar".into()],
        }];
        let xml = menu_xml(&launchers);
        assert!(xml.contains("<item label=\"Files\">"));
        assert!(xml.contains("'/opt/it'\\''s &lt;odd&gt; &amp; dir/thunar'"), "{xml}");
        assert!(xml.contains("client-list-combined-menu"));
        assert!(xml.contains("ToggleShowDesktop"));
        let empty = menu_xml(&[]);
        assert!(!empty.contains("<separator"), "no launchers, no stray separator");
    }

    #[test]
    fn rc_names_the_theme_the_menu_and_opens_the_menu_above_the_dock() {
        let rc = rc_xml(Path::new("/x/a&b/menu.xml"), 800, 3);
        assert!(rc.contains("<name>Bandito</name>"));
        assert!(rc.contains("<file>/x/a&amp;b/menu.xml</file>"));
        // Three launchers: 5 rows and a separator above the dock.
        assert!(
            rc.contains(&format!("<y>{}</y>", 800 - PANEL_HEIGHT - 6 - (5 * 24 + 12 + 4))),
            "{rc}"
        );
        assert!(rc.contains("<name>Onest</name>"));
        // Tiny screens do not underflow.
        assert!(rc_xml(Path::new("/m"), 10, 3).contains("<y>0</y>"));
    }

    #[test]
    fn theme_has_the_keys_openbox_needs_in_brand_colors() {
        let theme = themerc();
        for key in [
            "window.active.title.bg.color",
            "window.inactive.title.bg.color",
            "window.active.label.text.color",
            "menu.items.active.bg.color",
            "menu.border.color",
        ] {
            assert!(theme.contains(key), "{key}");
        }
        assert!(theme.contains("#221E1A") && theme.contains("#F3EBDD"));
        assert!(!theme.contains("#97b8e2"), "no Clearlooks blue left");
    }

    #[test]
    fn fonts_conf_includes_the_system_and_escapes_paths() {
        let conf = fonts_conf(Path::new("/a&b/fonts"), Path::new("/a&b/cache"));
        assert!(conf.contains("/etc/fonts/fonts.conf"));
        assert!(conf.contains("<dir>/a&amp;b/fonts</dir>"));
        assert!(conf.contains("<cachedir>/a&amp;b/cache</cachedir>"));
    }

    #[test]
    fn cursor_theme_is_the_first_installed() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(cursor_theme(tmp.path()), None);
        std::fs::create_dir_all(tmp.path().join("Yaru/cursors")).unwrap();
        assert_eq!(cursor_theme(tmp.path()), Some("Yaru"));
        std::fs::create_dir_all(tmp.path().join("Adwaita/cursors")).unwrap();
        assert_eq!(cursor_theme(tmp.path()), Some("Adwaita"));
    }

    #[test]
    fn prepare_writes_everything_in_its_own_folder_and_nothing_elsewhere() {
        let tmp = tempfile::tempdir().unwrap();
        let progs = tmp.path().join("progs");
        std::fs::create_dir(&progs).unwrap();
        fake_bin(&progs, &["google-chrome", "xfce4-terminal", "thunar"]);
        let icons = tmp.path().join("icons");
        std::fs::create_dir_all(icons.join("Adwaita/cursors")).unwrap();
        let dir = tmp.path().join("desktop");

        let prepared = prepare(&dir, progs.as_os_str(), &icons, 800).unwrap();
        assert_eq!(prepared.rc_file, dir.join("rc.xml"));
        assert_eq!(prepared.launchers.len(), 3);
        for file in [
            "rc.xml",
            "menu.xml",
            "fonts.conf",
            "fonts/Onest.ttf",
            "fonts/JetBrainsMono.ttf",
            "share/themes/Bandito/openbox-3/themerc",
            "bin/google-chrome",
            "bin/chromium",
        ] {
            assert!(dir.join(file).is_file(), "{file}");
        }
        let mode = std::fs::metadata(dir.join("bin/google-chrome"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700);
        let mode = std::fs::metadata(dir.join("rc.xml")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let get = |key: &str| prepared.env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
        assert_eq!(get("XCURSOR_THEME").as_deref(), Some("Adwaita"));
        assert_eq!(get("GTK_THEME").as_deref(), Some("Adwaita:dark"));
        assert!(get("PATH").unwrap().starts_with(&dir.join("bin").display().to_string()));
        assert!(get("FONTCONFIG_FILE").unwrap().ends_with("fonts.conf"));
        assert!(get("BROWSER").unwrap().ends_with("bin/google-chrome"));

        // A second start replaces the files without failing.
        prepare(&dir, progs.as_os_str(), &icons, 800).unwrap();
    }

    #[test]
    fn a_server_without_programs_still_gets_a_desktop() {
        let tmp = tempfile::tempdir().unwrap();
        let empty = tmp.path().join("empty");
        std::fs::create_dir(&empty).unwrap();
        let prepared = prepare(&tmp.path().join("d"), empty.as_os_str(), &tmp.path().join("icons"), 600).unwrap();
        assert!(prepared.launchers.is_empty());
        assert!(!prepared.env.iter().any(|(k, _)| k == "BROWSER" || k == "XCURSOR_THEME"));
    }

    #[test]
    fn the_browser_wrapper_runs_the_real_program_with_the_keyring_flag() {
        let tmp = tempfile::tempdir().unwrap();
        let wrapper_dir = tmp.path().join("own");
        let real_dir = tmp.path().join("real");
        std::fs::create_dir_all(&wrapper_dir).unwrap();
        std::fs::create_dir_all(&real_dir).unwrap();
        write_file(&wrapper_dir.join("chromium"), browser_wrapper().as_bytes(), 0o700).unwrap();
        let record = tmp.path().join("args.txt");
        let real = real_dir.join("chromium");
        std::fs::write(&real, format!("#!/bin/sh\necho \"$@\" > '{}'\n", record.display())).unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();

        let path = std::env::join_paths([
            wrapper_dir.as_path(),
            real_dir.as_path(),
            Path::new("/usr/bin"),
            Path::new("/bin"),
        ])
        .unwrap();
        let status = std::process::Command::new(wrapper_dir.join("chromium"))
            .arg("https://example.com")
            .env("PATH", &path)
            .status()
            .unwrap();
        assert!(status.success());
        let args = std::fs::read_to_string(&record).unwrap();
        assert!(args.contains("--password-store=basic"), "{args}");
        assert!(args.contains("https://example.com"), "{args}");
    }

    /// A folder with only the tools the browser wrapper calls (basename, dirname), to stand in for /usr/bin:/bin: a
    /// runner may have a real chromium there, which the wrapper would start.
    fn wrapper_tools(tmp: &Path) -> String {
        let tools = tmp.join("tools");
        std::fs::create_dir_all(&tools).unwrap();
        for tool in ["basename", "dirname"] {
            let found = ["/usr/bin", "/bin"]
                .iter()
                .map(|dir| Path::new(dir).join(tool))
                .find(|path| path.exists())
                .unwrap_or_else(|| panic!("{tool} is not installed"));
            std::os::unix::fs::symlink(found, tools.join(tool)).unwrap();
        }
        tools.display().to_string()
    }

    #[test]
    fn the_browser_wrapper_takes_path_entries_literally() {
        let tmp = tempfile::tempdir().unwrap();
        let wrapper_dir = tmp.path().join("own");
        let real_dir = tmp.path().join("real");
        std::fs::create_dir_all(&wrapper_dir).unwrap();
        std::fs::create_dir_all(&real_dir).unwrap();
        write_file(&wrapper_dir.join("chromium"), browser_wrapper().as_bytes(), 0o700).unwrap();
        let real = real_dir.join("chromium");
        std::fs::write(&real, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
        // `re*` would match the folder `real` if the shell expanded it; a PATH entry is a name, not a pattern.
        let path = format!(
            "{}:{}/re*:{}",
            wrapper_dir.display(),
            tmp.path().display(),
            wrapper_tools(tmp.path())
        );
        let status = std::process::Command::new(wrapper_dir.join("chromium"))
            .env("PATH", path)
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(127), "the wrapper expanded a glob in PATH");
    }

    #[test]
    fn the_browser_wrapper_does_not_call_itself_when_it_is_the_only_one() {
        let tmp = tempfile::tempdir().unwrap();
        let wrapper_dir = tmp.path().join("own");
        std::fs::create_dir_all(&wrapper_dir).unwrap();
        write_file(&wrapper_dir.join("chromium"), browser_wrapper().as_bytes(), 0o700).unwrap();
        // The wrapper's own folder twice, once spelled with a trailing slash.
        let own = format!("{}/", wrapper_dir.display());
        let path = format!("{}:{}:{}", wrapper_dir.display(), own, wrapper_tools(tmp.path()));
        let output = std::process::Command::new(wrapper_dir.join("chromium"))
            .env("PATH", path)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(127));
        assert!(String::from_utf8_lossy(&output.stderr).contains("not found"));
    }
}
