//! The desktop of the server screen (see docs/ARCHITECTURE.md#screen): the Bandito wallpaper, a dock with the
//! launchers, the windows and a clock, an openbox theme and menu in the brand's colors, and the starting of
//! Chrome in a way that works on a server. All of it is made from files and pictures the daemon writes into the
//! screen's own folder; nothing is installed on the server.

pub mod paint;
pub mod theme;
#[cfg(target_os = "linux")]
pub mod xpanel;
