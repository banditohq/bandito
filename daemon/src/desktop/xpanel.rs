//! The desktop of a screen, on X: the wallpaper on the root window and the dock (a window of type `DOCK` that
//! reserves its strip, so maximized windows stop above it). One thread per screen with one connection to the screen's
//! Xvfb. The pictures come from `paint`; this file only gets them onto the screen and turns clicks into actions.
//! The thread ends when the screen's Xvfb goes away or when `stop` is set.

use super::paint::{self, Fonts, Hit, Holder, LauncherItem, PANEL_HEIGHT, PanelLayout, PanelView, WindowItem};
use super::theme::{Launcher, MENU_KEY};
use std::collections::HashSet;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use x11rb::atom_manager;
use x11rb::connection::{Connection, RequestConnection};
use x11rb::properties::{WmSizeHints, WmSizeHintsSpecification};
use x11rb::protocol::Event;
use x11rb::protocol::xproto::{
    AtomEnum, ChangeWindowAttributesAux, ClientMessageEvent, ConnectionExt, CreateGCAux, CreateWindowAux, EventMask,
    ImageFormat, ImageOrder, PropMode, Window, WindowClass,
};
use x11rb::rust_connection::{DefaultStream, RustConnection};
use x11rb::wrapper::ConnectionExt as _;
use x11rb_protocol::parse_display::ConnectAddress;

/// `holder` values: nobody, an agent, the person.
pub const HOLDER_NONE: u8 = 0;
pub const HOLDER_AGENT: u8 = 1;
pub const HOLDER_USER: u8 = 2;

/// How long to wait for the window manager before the dock goes up without it.
const WM_WAIT: Duration = Duration::from_secs(3);

atom_manager! {
    Atoms: AtomsCookie {
        _NET_CLIENT_LIST,
        _NET_ACTIVE_WINDOW,
        _NET_WM_NAME,
        UTF8_STRING,
        _NET_WM_WINDOW_TYPE,
        _NET_WM_WINDOW_TYPE_DOCK,
        _NET_WM_WINDOW_TYPE_DESKTOP,
        _NET_WM_WINDOW_TYPE_SPLASH,
        _NET_WM_WINDOW_TYPE_MENU,
        _NET_WM_WINDOW_TYPE_POPUP_MENU,
        _NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
        _NET_WM_WINDOW_TYPE_TOOLTIP,
        _NET_WM_WINDOW_TYPE_NOTIFICATION,
        _NET_WM_WINDOW_TYPE_COMBO,
        _NET_WM_WINDOW_TYPE_DND,
        _NET_WM_STATE,
        _NET_WM_STATE_HIDDEN,
        _NET_WM_STATE_SKIP_TASKBAR,
        _NET_WM_STATE_SKIP_PAGER,
        _NET_WM_STATE_ABOVE,
        _NET_WM_STATE_STICKY,
        _NET_WM_STRUT,
        _NET_WM_STRUT_PARTIAL,
        _NET_WM_DESKTOP,
        _NET_SUPPORTING_WM_CHECK,
        WM_CHANGE_STATE,
        WM_NAME,
        WM_CLASS,
        _XROOTPMAP_ID,
        ESETROOT_PMAP_ID,
    }
}

/// What the desktop thread needs to know about its screen.
pub struct Params {
    pub display: u32,
    pub width: u32,
    pub height: u32,
    /// The screen's MIT-MAGIC-COOKIE-1, as 32 hex digits.
    pub cookie: String,
    pub launchers: Vec<Launcher>,
    /// `DISPLAY`, `XAUTHORITY` and the desktop's own variables, for the programs the dock starts.
    pub env: Vec<(String, String)>,
    /// Process groups of programs started on the screen; killed when it stops (`screen.rs`).
    pub launched: Arc<Mutex<Vec<i32>>>,
    /// Who holds the controls: `HOLDER_*`.
    pub holder: Arc<AtomicU8>,
    pub stop: Arc<AtomicBool>,
}

/// Starts the desktop thread. A failure inside only logs: the screen works without its desktop.
pub fn spawn(params: Params) -> std::io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new()
        .name("screen-desktop".into())
        .spawn(move || {
            let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&params)));
            let panicked = caught.is_err();
            let outcome = caught.unwrap_or_else(|panic| {
                let what = panic
                    .downcast_ref::<&str>()
                    .map(|s| (*s).to_string())
                    .or_else(|| panic.downcast_ref::<String>().cloned())
                    .unwrap_or_else(|| "unknown panic".to_string());
                Err(format!("the dock thread panicked: {what}").into())
            });
            if let Err(e) = outcome {
                // Stopping the screen takes the X server away under the thread: not a problem to report. A panic is.
                if panicked {
                    tracing::error!("the screen has no dock: {e}");
                } else if params.stop.load(Ordering::Relaxed) {
                    tracing::debug!("the screen's desktop ended with its screen: {e}");
                } else {
                    tracing::warn!("the screen's desktop stopped: {e}");
                }
            }
        })
}

type Fail = Box<dyn std::error::Error + Send + Sync>;

fn connect(display: u32, cookie: &str) -> Result<(RustConnection, usize), Fail> {
    let auth = hex::decode(cookie)?;
    let path = format!("/tmp/.X11-unix/X{display}");
    let (stream, _) = DefaultStream::connect(&ConnectAddress::Socket(path))?;
    let conn = RustConnection::connect_to_stream_with_auth_info(stream, 0, b"MIT-MAGIC-COOKIE-1".to_vec(), auth)?;
    Ok((conn, 0))
}

fn run(params: &Params) -> Result<(), Fail> {
    let fonts = Fonts::load().ok_or("the bundled fonts do not load")?;
    let (conn, screen_num) = connect(params.display, &params.cookie)?;
    let screen = conn.setup().roots[screen_num].clone();
    let root = screen.root;
    let depth = screen.root_depth;
    let atoms = Atoms::new(&conn)?.reply()?;

    // Only the usual 24-bit, 32-bits-a-pixel, little-endian screen: pictures are sent as B, G, R, pad.
    let usable = conn.setup().image_byte_order == ImageOrder::LSB_FIRST
        && depth == 24
        && conn
            .setup()
            .pixmap_formats
            .iter()
            .any(|f| f.depth == 24 && f.bits_per_pixel == 32);
    if !usable {
        return Err("the screen's pixel format is not 24-bit 32bpp little endian".into());
    }
    let (width, height) = (u32::from(screen.width_in_pixels), u32::from(screen.height_in_pixels));

    wait_for_window_manager(&conn, root, &atoms, &params.stop);
    set_wallpaper(&conn, root, depth, &atoms, &fonts, width, height)?;

    let panel_y = height.saturating_sub(PANEL_HEIGHT) as i16;
    let win = conn.generate_id()?;
    conn.create_window(
        depth,
        win,
        root,
        0,
        panel_y,
        width as u16,
        PANEL_HEIGHT as u16,
        0,
        WindowClass::INPUT_OUTPUT,
        0,
        &CreateWindowAux::new().background_pixel(screen.black_pixel).event_mask(
            EventMask::EXPOSURE
                | EventMask::BUTTON_PRESS
                | EventMask::BUTTON_RELEASE
                | EventMask::POINTER_MOTION
                | EventMask::LEAVE_WINDOW
                | EventMask::ENTER_WINDOW,
        ),
    )?;
    // Where the dock goes, said the way a window manager must obey: position and size given by the program.
    let hints = WmSizeHints {
        position: Some((WmSizeHintsSpecification::UserSpecified, 0, i32::from(panel_y))),
        size: Some((
            WmSizeHintsSpecification::UserSpecified,
            width as i32,
            PANEL_HEIGHT as i32,
        )),
        min_size: Some((width as i32, PANEL_HEIGHT as i32)),
        max_size: Some((width as i32, PANEL_HEIGHT as i32)),
        ..WmSizeHints::default()
    };
    hints.set_normal_hints(&conn, win)?;
    let title = "Bandito dock";
    conn.change_property8(
        PropMode::REPLACE,
        win,
        atoms._NET_WM_NAME,
        atoms.UTF8_STRING,
        title.as_bytes(),
    )?;
    conn.change_property8(
        PropMode::REPLACE,
        win,
        atoms.WM_NAME,
        AtomEnum::STRING,
        title.as_bytes(),
    )?;
    conn.change_property8(
        PropMode::REPLACE,
        win,
        atoms.WM_CLASS,
        AtomEnum::STRING,
        b"bandito-dock\0Bandito\0",
    )?;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        atoms._NET_WM_WINDOW_TYPE,
        AtomEnum::ATOM,
        &[atoms._NET_WM_WINDOW_TYPE_DOCK],
    )?;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        atoms._NET_WM_STATE,
        AtomEnum::ATOM,
        &[
            atoms._NET_WM_STATE_ABOVE,
            atoms._NET_WM_STATE_STICKY,
            atoms._NET_WM_STATE_SKIP_TASKBAR,
            atoms._NET_WM_STATE_SKIP_PAGER,
        ],
    )?;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        atoms._NET_WM_DESKTOP,
        AtomEnum::CARDINAL,
        &[0xFFFF_FFFF],
    )?;
    let bottom = PANEL_HEIGHT;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        atoms._NET_WM_STRUT,
        AtomEnum::CARDINAL,
        &[0, 0, 0, bottom],
    )?;
    conn.change_property32(
        PropMode::REPLACE,
        win,
        atoms._NET_WM_STRUT_PARTIAL,
        AtomEnum::CARDINAL,
        &[0, 0, 0, bottom, 0, 0, 0, 0, 0, 0, 0, width.saturating_sub(1)],
    )?;
    conn.map_window(win)?;
    let gc = conn.generate_id()?;
    conn.create_gc(gc, win, &CreateGCAux::new())?;
    conn.change_window_attributes(
        root,
        &ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE),
    )?;
    conn.flush()?;

    let mut dock = Dock {
        conn: &conn,
        params,
        fonts: &fonts,
        atoms: &atoms,
        root,
        win,
        gc,
        depth,
        width,
        launchers: params
            .launchers
            .iter()
            .map(|l| LauncherItem {
                kind: l.kind,
                label: l.kind.label().to_string(),
            })
            .collect(),
        windows: Vec::new(),
        watched: HashSet::new(),
        hover: None,
        pressed: None,
        layout: PanelLayout::default(),
        shown: None,
        picture: Vec::new(),
    };
    dock.event_loop()
}

/// openbox says it runs by setting `_NET_SUPPORTING_WM_CHECK` on the root window.
fn wait_for_window_manager(conn: &RustConnection, root: Window, atoms: &Atoms, stop: &AtomicBool) {
    let deadline = Instant::now() + WM_WAIT;
    while Instant::now() < deadline && !stop.load(Ordering::Relaxed) {
        let present = conn
            .get_property(false, root, atoms._NET_SUPPORTING_WM_CHECK, AtomEnum::WINDOW, 0, 1)
            .ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|r| r.value32().is_some_and(|mut v| v.next().is_some()));
        if present {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Sends `data` as rows that fit in one request each.
#[allow(clippy::too_many_arguments)]
fn put_image(
    conn: &RustConnection,
    drawable: u32,
    gc: u32,
    depth: u8,
    width: u32,
    height: u32,
    bgrx: &[u8],
) -> Result<(), Fail> {
    let stride = width as usize * 4;
    if stride == 0 || bgrx.len() < stride * height as usize {
        return Err("picture is smaller than its size".into());
    }
    let room = conn.maximum_request_bytes().saturating_sub(64);
    let rows_per_request = (room / stride).clamp(1, height as usize);
    let mut y = 0usize;
    while y < height as usize {
        let rows = rows_per_request.min(height as usize - y);
        conn.put_image(
            ImageFormat::Z_PIXMAP,
            drawable,
            gc,
            width as u16,
            rows as u16,
            0,
            y as i16,
            0,
            depth,
            &bgrx[y * stride..(y + rows) * stride],
        )?;
        y += rows;
    }
    Ok(())
}

/// Draws the wallpaper into a pixmap and makes it the root window's background. The pixmap lives as long as this
/// connection, which is as long as the screen.
fn set_wallpaper(
    conn: &RustConnection,
    root: Window,
    depth: u8,
    atoms: &Atoms,
    fonts: &Fonts,
    width: u32,
    height: u32,
) -> Result<(), Fail> {
    let picture = paint::to_bgrx(&paint::wallpaper(fonts, width, height));
    let pixmap = conn.generate_id()?;
    conn.create_pixmap(depth, pixmap, root, width as u16, height as u16)?;
    let gc = conn.generate_id()?;
    conn.create_gc(gc, pixmap, &CreateGCAux::new())?;
    put_image(conn, pixmap, gc, depth, width, height, &picture)?;
    conn.change_window_attributes(root, &ChangeWindowAttributesAux::new().background_pixmap(pixmap))?;
    conn.clear_area(false, root, 0, 0, 0, 0)?;
    for atom in [atoms._XROOTPMAP_ID, atoms.ESETROOT_PMAP_ID] {
        conn.change_property32(PropMode::REPLACE, root, atom, AtomEnum::PIXMAP, &[pixmap])?;
    }
    conn.free_gc(gc)?;
    conn.flush()?;
    Ok(())
}

struct Dock<'a> {
    conn: &'a RustConnection,
    params: &'a Params,
    fonts: &'a Fonts,
    atoms: &'a Atoms,
    root: Window,
    win: Window,
    gc: u32,
    depth: u8,
    width: u32,
    launchers: Vec<LauncherItem>,
    windows: Vec<WindowItem>,
    /// Windows whose property changes we listen to.
    watched: HashSet<Window>,
    hover: Option<Hit>,
    /// What the primary button went down on.
    pressed: Option<Hit>,
    layout: PanelLayout,
    /// What the picture on the dock shows now.
    shown: Option<PanelView>,
    /// The BGRX bytes of that picture, for `Expose`.
    picture: Vec<u8>,
}

impl Dock<'_> {
    fn event_loop(&mut self) -> Result<(), Fail> {
        let fd = self.conn.stream().as_raw_fd();
        self.refresh_windows();
        loop {
            if self.params.stop.load(Ordering::Relaxed) {
                return Ok(());
            }
            while let Some(event) = self.conn.poll_for_event()? {
                self.handle(event);
            }
            self.redraw_if_changed()?;
            self.conn.flush()?;
            wait_readable(fd, 1000);
        }
    }

    fn handle(&mut self, event: Event) {
        match event {
            Event::Expose(e) if e.window == self.win && e.count == 0 => self.paint_cached(),
            Event::MotionNotify(e) if e.event == self.win => {
                self.set_hover(self.layout.hit(i32::from(e.event_x), i32::from(e.event_y)));
            }
            Event::LeaveNotify(e) if e.event == self.win => self.set_hover(None),
            Event::ButtonPress(e) if e.event == self.win && e.detail == 1 => {
                self.pressed = self.layout.hit(i32::from(e.event_x), i32::from(e.event_y));
            }
            // A button acts when it is let go over the place where it was pressed, as buttons do. The menu needs it:
            // opened while the button is still down, it would close with the release.
            Event::ButtonRelease(e) if e.event == self.win && e.detail == 1 => {
                let released = self.layout.hit(i32::from(e.event_x), i32::from(e.event_y));
                if let (Some(hit), Some(pressed)) = (released, self.pressed.take())
                    && hit == pressed
                {
                    self.click(hit);
                }
            }
            Event::PropertyNotify(e) => {
                let a = self.atoms;
                let tracked = [
                    a._NET_CLIENT_LIST,
                    a._NET_ACTIVE_WINDOW,
                    a._NET_WM_NAME,
                    a.WM_NAME,
                    a._NET_WM_STATE,
                ];
                if tracked.contains(&e.atom) && (e.window == self.root || self.watched.contains(&e.window)) {
                    self.refresh_windows();
                }
            }
            _ => {}
        }
    }

    fn set_hover(&mut self, hover: Option<Hit>) {
        if self.hover != hover {
            self.hover = hover;
        }
    }

    fn click(&mut self, hit: Hit) {
        match hit {
            Hit::Menu => self.start(&["xdotool".to_string(), "key".to_string(), MENU_KEY.to_string()]),
            Hit::Launcher(i) => {
                if let Some(launcher) = self.params.launchers.get(i) {
                    let argv = launcher.argv.clone();
                    self.start(&argv);
                }
            }
            Hit::Window(i) => {
                if let Some(item) = self.windows.get(i).cloned() {
                    if item.active && !item.hidden {
                        self.send_to_root(item.id, self.atoms.WM_CHANGE_STATE, [3, 0, 0, 0, 0]);
                    } else {
                        self.send_to_root(item.id, self.atoms._NET_ACTIVE_WINDOW, [2, 0, 0, 0, 0]);
                    }
                }
            }
        }
    }

    fn send_to_root(&self, window: Window, message_type: u32, data: [u32; 5]) {
        let event = ClientMessageEvent::new(32, window, message_type, data);
        let mask = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
        if let Err(e) = self.conn.send_event(false, self.root, mask, event) {
            tracing::debug!("the dock could not reach the window manager: {e}");
        }
    }

    fn start(&self, argv: &[String]) {
        spawn_detached(argv, &self.params.env, &self.params.launched, &self.params.stop);
    }

    /// Reads the window list and the active window from the window manager.
    fn refresh_windows(&mut self) {
        let a = self.atoms;
        let ids = self.property32(self.root, a._NET_CLIENT_LIST, AtomEnum::WINDOW);
        let active = self
            .property32(self.root, a._NET_ACTIVE_WINDOW, AtomEnum::WINDOW)
            .first()
            .copied()
            .unwrap_or(0);
        let hidden_types = [
            a._NET_WM_WINDOW_TYPE_DOCK,
            a._NET_WM_WINDOW_TYPE_DESKTOP,
            a._NET_WM_WINDOW_TYPE_SPLASH,
            a._NET_WM_WINDOW_TYPE_MENU,
            a._NET_WM_WINDOW_TYPE_POPUP_MENU,
            a._NET_WM_WINDOW_TYPE_DROPDOWN_MENU,
            a._NET_WM_WINDOW_TYPE_TOOLTIP,
            a._NET_WM_WINDOW_TYPE_NOTIFICATION,
            a._NET_WM_WINDOW_TYPE_COMBO,
            a._NET_WM_WINDOW_TYPE_DND,
        ];
        let mut windows = Vec::new();
        for id in ids {
            if id == self.win {
                continue;
            }
            if self.watched.insert(id) {
                let _ = self.conn.change_window_attributes(
                    id,
                    &ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE),
                );
            }
            let types = self.property32(id, a._NET_WM_WINDOW_TYPE, AtomEnum::ATOM);
            if types.iter().any(|t| hidden_types.contains(t)) {
                continue;
            }
            let state = self.property32(id, a._NET_WM_STATE, AtomEnum::ATOM);
            if state.contains(&a._NET_WM_STATE_SKIP_TASKBAR) {
                continue;
            }
            let mut title = self.property_text(id, a._NET_WM_NAME, a.UTF8_STRING);
            if title.is_empty() {
                title = self.property_text(id, a.WM_NAME, AtomEnum::STRING.into());
            }
            if title.is_empty() {
                title = "Window".to_string();
            }
            windows.push(WindowItem {
                id,
                title,
                active: id == active,
                hidden: state.contains(&a._NET_WM_STATE_HIDDEN),
            });
        }
        // Forget windows that are gone, so the set does not grow for ever.
        let present: HashSet<Window> = windows.iter().map(|w| w.id).collect();
        self.watched.retain(|w| present.contains(w));
        self.windows = windows;
    }

    fn property32(&self, window: Window, property: u32, kind: AtomEnum) -> Vec<u32> {
        self.conn
            .get_property(false, window, property, kind, 0, 4096)
            .ok()
            .and_then(|c| c.reply().ok())
            .and_then(|r| r.value32().map(Iterator::collect))
            .unwrap_or_default()
    }

    fn property_text(&self, window: Window, property: u32, kind: u32) -> String {
        self.conn
            .get_property(false, window, property, kind, 0, 1024)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| String::from_utf8_lossy(&r.value).trim().to_string())
            .unwrap_or_default()
    }

    fn view(&self) -> PanelView {
        let now = chrono::Local::now();
        PanelView {
            launchers: self.launchers.clone(),
            windows: self.windows.clone(),
            hover: self.hover,
            time: now.format("%H:%M").to_string(),
            date: now.format("%a %-d %b").to_string(),
            holder: match self.params.holder.load(Ordering::Relaxed) {
                HOLDER_AGENT => Some(Holder::Agent),
                HOLDER_USER => Some(Holder::User),
                _ => None,
            },
        }
    }

    /// Draws the dock again when what it shows has changed since the last picture.
    fn redraw_if_changed(&mut self) -> Result<(), Fail> {
        let view = self.view();
        if self.shown.as_ref() == Some(&view) {
            return Ok(());
        }
        let (pixmap, layout) = paint::panel(self.fonts, self.width, &view);
        self.picture = paint::to_bgrx(&pixmap);
        self.layout = layout;
        self.shown = Some(view);
        self.paint_cached();
        Ok(())
    }

    fn paint_cached(&self) {
        if self.picture.is_empty() {
            return;
        }
        if let Err(e) = put_image(
            self.conn,
            self.win,
            self.gc,
            self.depth,
            self.width,
            PANEL_HEIGHT,
            &self.picture,
        ) {
            tracing::debug!("the dock could not be drawn: {e}");
        }
    }
}

/// Waits until `fd` can be read or `timeout_ms` has passed.
fn wait_readable(fd: i32, timeout_ms: i32) {
    let mut poll_fd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one valid pollfd that lives through the call; a failed or interrupted poll only means "look again".
    unsafe {
        libc::poll(&mut poll_fd, 1, timeout_ms);
    }
}

/// Starts a program on the screen in a group of its own, with no stdio, and remembers the group so that stopping
/// the screen stops the program. Nothing starts once `stop` is set, and the check is made while the list is locked,
/// the same lock `stop_launched` reads it under. The group stays in the list while any process of it lives, even
/// after the first one has exited (a browser that detaches), so stopping the screen still signals it.
pub fn spawn_detached(
    argv: &[String],
    env: &[(String, String)],
    launched: &Arc<Mutex<Vec<i32>>>,
    stop: &Arc<AtomicBool>,
) {
    let Some(program) = argv.first() else { return };
    let mut command = Command::new(program);
    command
        .args(&argv[1..])
        .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0);
    let Ok(mut list) = launched.lock() else { return };
    if stop.load(Ordering::SeqCst) {
        return;
    }
    match command.spawn() {
        Ok(mut child) => {
            let pgid = child.id() as i32;
            list.push(pgid);
            drop(list);
            let launched = Arc::clone(launched);
            let stop = Arc::clone(stop);
            std::thread::spawn(move || {
                let _ = child.wait();
                while crate::screen::group_alive(pgid) && !stop.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(200));
                }
                if let Ok(mut list) = launched.lock() {
                    list.retain(|&p| p != pgid);
                }
            });
        }
        Err(e) => tracing::warn!("the dock could not start {program}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &std::path::Path, body: &str) -> String {
        let path = dir.join("prog.sh");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path.display().to_string()
    }

    fn state() -> (Arc<Mutex<Vec<i32>>>, Arc<AtomicBool>) {
        (Arc::new(Mutex::new(Vec::new())), Arc::new(AtomicBool::new(false)))
    }

    fn eventually(mut ready: impl FnMut() -> bool) -> bool {
        for _ in 0..100 {
            if ready() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        ready()
    }

    #[test]
    fn nothing_starts_after_the_screen_is_stopping() {
        let tmp = tempfile::tempdir().unwrap();
        let marker = tmp.path().join("ran");
        let program = script(tmp.path(), &format!("touch '{}'", marker.display()));
        let (launched, stop) = state();
        stop.store(true, Ordering::SeqCst);
        spawn_detached(&[program], &[], &launched, &stop);
        std::thread::sleep(Duration::from_millis(300));
        assert!(!marker.exists(), "a program was started on a stopping screen");
        assert!(launched.lock().unwrap().is_empty());
    }

    #[test]
    fn a_program_is_listed_while_it_runs_and_forgotten_when_its_group_is_gone() {
        let tmp = tempfile::tempdir().unwrap();
        let program = script(tmp.path(), "exit 0");
        let (launched, stop) = state();
        spawn_detached(&[program], &[], &launched, &stop);
        assert!(eventually(|| launched.lock().unwrap().is_empty()));
    }

    #[test]
    fn a_group_stays_listed_while_a_detached_member_lives() {
        let tmp = tempfile::tempdir().unwrap();
        // The leader exits at once and leaves a member in the same group, as a browser that detaches does.
        let program = script(tmp.path(), "sleep 30 &\nexit 0");
        let (launched, stop) = state();
        spawn_detached(&[program], &[], &launched, &stop);
        std::thread::sleep(Duration::from_millis(800));
        let groups = launched.lock().unwrap().clone();
        assert_eq!(groups.len(), 1, "the group left the list while its member runs");
        // Stopping the screen signals it, and then it leaves the list.
        // SAFETY: killpg only sends a signal to the group this test made.
        unsafe { libc::killpg(groups[0], libc::SIGTERM) };
        assert!(eventually(|| launched.lock().unwrap().is_empty()));
    }
}
