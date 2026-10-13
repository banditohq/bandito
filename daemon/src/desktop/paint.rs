//! Pictures of the screen's desktop: the wallpaper and the dock, drawn in memory with `tiny-skia` and the
//! bundled Onest and JetBrains Mono. Nothing here talks to X, so every picture is tested on any system.
//! Colors are the dark tokens of `brand/tokens/tokens.json` (docs/DESIGN_LANGUAGE.md).

use super::theme::LauncherKind;
use ab_glyph::{Font, FontRef, PxScale, ScaleFont, VariableFont};
use tiny_skia::{
    Color, FillRule, GradientStop, Paint, Path, PathBuilder, Pixmap, PixmapPaint, Point, RadialGradient, Rect,
    SpreadMode, Stroke, Transform,
};

/// Height of the dock in pixels.
pub const PANEL_HEIGHT: u32 = 48;
/// The raccoon mark and the lockup (wordmark), cream on a transparent ground, from `brand/logo/`.
const MARK_PNG: &[u8] = include_bytes!("../../assets/desktop/mark.png");
const LOCKUP_PNG: &[u8] = include_bytes!("../../assets/desktop/lockup.png");
const ONEST_TTF: &[u8] = include_bytes!("../../assets/desktop/Onest.ttf");
const MONO_TTF: &[u8] = include_bytes!("../../assets/desktop/JetBrainsMono.ttf");

/// The brand colors the desktop uses, as `0xRRGGBB`.
pub mod color {
    pub const BG: u32 = 0x12100E;
    pub const SURFACE1: u32 = 0x1A1714;
    pub const TEXT: u32 = 0xF3EBDD;
    pub const TEXT2: u32 = 0xBDB2A0;
    pub const TEXT3: u32 = 0x867C6D;
    pub const SIGNAL: u32 = 0xFF8A1F;
    pub const OK: u32 = 0xA9C7A2;
}

/// A color from `0xRRGGBB` and an opacity from 0 to 1.
fn rgba(hex: u32, alpha: f32) -> Color {
    let channel = |shift: u32| f32::from(((hex >> shift) & 0xFF) as u8) / 255.0;
    Color::from_rgba(channel(16), channel(8), channel(0), alpha.clamp(0.0, 1.0)).unwrap_or(Color::BLACK)
}

fn paint_of(color: Color) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = true;
    paint
}

/// The fonts of the desktop, made once per screen.
pub struct Fonts {
    regular: FontRef<'static>,
    medium: FontRef<'static>,
    mono: FontRef<'static>,
}

impl Fonts {
    /// `None` only if a bundled font does not parse, which a test prevents.
    pub fn load() -> Option<Self> {
        let regular = FontRef::try_from_slice(ONEST_TTF).ok()?;
        let mut medium = regular.clone();
        medium.set_variation(b"wght", 560.0);
        let mut mono = FontRef::try_from_slice(MONO_TTF).ok()?;
        mono.set_variation(b"wght", 500.0);
        Some(Self { regular, medium, mono })
    }
}

/// Width of `text` in pixels at `size`.
fn text_width(font: &FontRef<'_>, size: f32, text: &str) -> f32 {
    let scaled = font.as_scaled(PxScale::from(size));
    let mut width = 0.0;
    let mut previous = None;
    for c in text.chars() {
        let id = scaled.glyph_id(c);
        if let Some(prev) = previous {
            width += scaled.kern(prev, id);
        }
        width += scaled.h_advance(id);
        previous = Some(id);
    }
    width
}

/// `text` cut with an ellipsis so it is at most `max_width` wide.
fn fit_text(font: &FontRef<'_>, size: f32, text: &str, max_width: f32) -> String {
    if text_width(font, size, text) <= max_width {
        return text.to_string();
    }
    let mut kept: Vec<char> = text.chars().collect();
    while !kept.is_empty() {
        kept.pop();
        let candidate: String = kept.iter().collect::<String>().trim_end().to_string() + "\u{2026}";
        if text_width(font, size, &candidate) <= max_width {
            return candidate;
        }
    }
    String::new()
}

/// Draws `text` with its baseline at `baseline` and its left edge at `x`. Returns nothing: callers measure first.
fn draw_text(pm: &mut Pixmap, font: &FontRef<'_>, size: f32, x: f32, baseline: f32, text: &str, color: Color) {
    let scale = PxScale::from(size);
    let scaled = font.as_scaled(scale);
    let (width, height) = (pm.width() as i32, pm.height() as i32);
    let (r, g, b, a) = (color.red(), color.green(), color.blue(), color.alpha());
    let data = pm.data_mut();
    let mut cursor = x;
    let mut previous = None;
    for c in text.chars() {
        let id = scaled.glyph_id(c);
        if let Some(prev) = previous {
            cursor += scaled.kern(prev, id);
        }
        let glyph = id.with_scale_and_position(scale, ab_glyph::point(cursor, baseline));
        cursor += scaled.h_advance(id);
        previous = Some(id);
        let Some(outlined) = font.outline_glyph(glyph) else {
            continue;
        };
        let bounds = outlined.px_bounds();
        let (left, top) = (bounds.min.x as i32, bounds.min.y as i32);
        outlined.draw(|gx, gy, coverage| {
            let (px, py) = (left + gx as i32, top + gy as i32);
            if px < 0 || py < 0 || px >= width || py >= height {
                return;
            }
            let alpha = coverage * a;
            let at = ((py * width + px) * 4) as usize;
            let keep = 1.0 - alpha;
            let blend = |dst: u8, src: f32| (f32::from(dst) * keep + src * alpha * 255.0).round().min(255.0) as u8;
            data[at] = blend(data[at], r);
            data[at + 1] = blend(data[at + 1], g);
            data[at + 2] = blend(data[at + 2], b);
            data[at + 3] = blend(data[at + 3], 1.0);
        });
    }
}

/// A rounded rectangle, as a path.
fn rounded_rect(x: f32, y: f32, w: f32, h: f32, radius: f32) -> Option<Path> {
    let r = radius.min(w / 2.0).min(h / 2.0).max(0.0);
    let k = 0.552_284_8 * r;
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pb.line_to(x, y + r);
    pb.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    pb.close();
    pb.finish()
}

fn fill_rrect(pm: &mut Pixmap, rect: [f32; 4], radius: f32, color: Color) {
    if let Some(path) = rounded_rect(rect[0], rect[1], rect[2], rect[3], radius) {
        pm.fill_path(&path, &paint_of(color), FillRule::Winding, Transform::identity(), None);
    }
}

/// A one-pixel outline drawn inside `rect`.
fn stroke_rrect(pm: &mut Pixmap, rect: [f32; 4], radius: f32, color: Color) {
    if let Some(path) = rounded_rect(rect[0] + 0.5, rect[1] + 0.5, rect[2] - 1.0, rect[3] - 1.0, radius) {
        // Just over one pixel: a stroke of exactly 1 is a hairline, which tiny-skia draws with a path that trips an
        // internal assertion on some shapes.
        let stroke = Stroke {
            width: 1.05,
            ..Stroke::default()
        };
        pm.stroke_path(&path, &paint_of(color), &stroke, Transform::identity(), None);
    }
}

/// A solid rectangle on whole pixels. Not anti-aliased: tiny-skia's anti-aliased rectangle fill trips an internal
/// assertion on one-pixel rectangles.
fn fill_px(pm: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, color: Color) {
    let mut paint = Paint::default();
    paint.set_color(color);
    paint.anti_alias = false;
    if let Some(rect) = Rect::from_xywh(x.round(), y.round(), w.round().max(1.0), h.round().max(1.0)) {
        pm.fill_rect(rect, &paint, Transform::identity(), None);
    }
}

fn fill_circle(pm: &mut Pixmap, cx: f32, cy: f32, radius: f32, color: Color) {
    if let Some(path) = PathBuilder::from_circle(cx, cy, radius) {
        pm.fill_path(&path, &paint_of(color), FillRule::Winding, Transform::identity(), None);
    }
}

/// A picture scaled to `width` and placed with its top-left corner at `x`, `y`.
fn draw_scaled(pm: &mut Pixmap, picture: &Pixmap, x: f32, y: f32, width: f32, opacity: f32) {
    if picture.width() == 0 || width <= 0.0 {
        return;
    }
    let scale = width / picture.width() as f32;
    let paint = PixmapPaint {
        opacity,
        quality: tiny_skia::FilterQuality::Bicubic,
        ..PixmapPaint::default()
    };
    pm.draw_pixmap(
        0,
        0,
        picture.as_ref(),
        &paint,
        Transform::from_translate(x, y).pre_scale(scale, scale),
        None,
    );
}

/// The three icons of the dock, on the brand's 24-point grid with a 1.6 stroke, round caps and joins.
fn draw_icon(pm: &mut Pixmap, kind: LauncherKind, x: f32, y: f32, size: f32, color: Color) {
    let mut pb = PathBuilder::new();
    match kind {
        LauncherKind::Browser => {
            // Globe: circle, a meridian and the equator.
            if let Some(circle) = PathBuilder::from_circle(12.0, 12.0, 9.0) {
                pb.push_path(&circle);
            }
            pb.move_to(3.0, 12.0);
            pb.line_to(21.0, 12.0);
            pb.move_to(12.0, 3.0);
            pb.cubic_to(7.5, 7.0, 7.5, 17.0, 12.0, 21.0);
            pb.move_to(12.0, 3.0);
            pb.cubic_to(16.5, 7.0, 16.5, 17.0, 12.0, 21.0);
        }
        LauncherKind::Terminal => {
            // A window with the raccoon's `>` eye and a cursor line.
            if let Some(frame) = rounded_rect(3.0, 4.5, 18.0, 15.0, 3.5) {
                pb.push_path(&frame);
            }
            pb.move_to(7.5, 9.5);
            pb.line_to(10.5, 12.0);
            pb.line_to(7.5, 14.5);
            pb.move_to(12.5, 15.0);
            pb.line_to(16.5, 15.0);
        }
        LauncherKind::Files => {
            // A folder with a tab.
            pb.move_to(3.5, 7.0);
            pb.cubic_to(3.5, 5.9, 4.4, 5.0, 5.5, 5.0);
            pb.line_to(9.2, 5.0);
            pb.line_to(11.2, 7.2);
            pb.line_to(18.5, 7.2);
            pb.cubic_to(19.6, 7.2, 20.5, 8.1, 20.5, 9.2);
            pb.line_to(20.5, 17.0);
            pb.cubic_to(20.5, 18.1, 19.6, 19.0, 18.5, 19.0);
            pb.line_to(5.5, 19.0);
            pb.cubic_to(4.4, 19.0, 3.5, 18.1, 3.5, 17.0);
            pb.close();
        }
    }
    let Some(path) = pb.finish() else { return };
    let scale = size / 24.0;
    let stroke = Stroke {
        width: 1.6,
        line_cap: tiny_skia::LineCap::Round,
        line_join: tiny_skia::LineJoin::Round,
        ..Stroke::default()
    };
    pm.stroke_path(
        &path,
        &paint_of(color),
        &stroke,
        Transform::from_translate(x, y).pre_scale(scale, scale),
        None,
    );
}

/// The wallpaper for a screen of `width` x `height`: the warm dark ground with a glow and a grid that fades
/// out, the Bandito lockup in the middle of what the dock leaves free, and the site under it.
pub fn wallpaper(fonts: &Fonts, width: u32, height: u32) -> Pixmap {
    let mut pm = Pixmap::new(width.max(1), height.max(1)).unwrap_or_else(|| Pixmap::new(1, 1).expect("1x1 pixmap"));
    let (w, h) = (width as f32, height as f32);
    let free_h = (h - PANEL_HEIGHT as f32).max(1.0);
    let (cx, cy) = (w / 2.0, free_h * 0.46);
    let reach = w.max(h) * 0.8;

    // Ground: a lit center falling into the bg token's darker edge.
    let ground = RadialGradient::new(
        Point::from_xy(cx, cy),
        Point::from_xy(cx, cy),
        reach,
        vec![
            GradientStop::new(0.0, rgba(0x241E19, 1.0)),
            GradientStop::new(0.55, rgba(color::BG, 1.0)),
            GradientStop::new(1.0, rgba(0x0A0908, 1.0)),
        ],
        SpreadMode::Pad,
        Transform::identity(),
    );
    if let (Some(shader), Some(rect)) = (ground, Rect::from_xywh(0.0, 0.0, w, h)) {
        let paint = Paint {
            shader,
            ..Paint::default()
        };
        pm.fill_rect(rect, &paint, Transform::identity(), None);
    } else {
        pm.fill(rgba(color::BG, 1.0));
    }

    // A grid of dots that fades out away from the center, as on the brand's pages.
    let step = 32.0;
    let fade_reach = w.max(h) * 0.62;
    let mut y = step / 2.0;
    while y < free_h {
        let mut x = step / 2.0;
        while x < w {
            let distance = ((x - cx).powi(2) + (y - cy).powi(2)).sqrt();
            let fade = (1.0 - distance / fade_reach).clamp(0.0, 1.0);
            if fade > 0.02 {
                fill_circle(&mut pm, x, y, 0.9, rgba(color::TEXT, 0.22 * fade.powf(1.5)));
            }
            x += step;
        }
        y += step;
    }

    // A faint warm glow behind the lockup.
    let glow = RadialGradient::new(
        Point::from_xy(cx, cy),
        Point::from_xy(cx, cy),
        w.min(free_h) * 0.5,
        vec![
            GradientStop::new(0.0, rgba(color::SIGNAL, 0.075)),
            GradientStop::new(1.0, rgba(color::SIGNAL, 0.0)),
        ],
        SpreadMode::Pad,
        Transform::identity(),
    );
    if let (Some(shader), Some(rect)) = (glow, Rect::from_xywh(0.0, 0.0, w, free_h)) {
        let paint = Paint {
            shader,
            ..Paint::default()
        };
        pm.fill_rect(rect, &paint, Transform::identity(), None);
    }

    if let Ok(lockup) = Pixmap::decode_png(LOCKUP_PNG) {
        let lockup_w = (w * 0.34).clamp(260.0, 700.0).min(w * 0.8);
        let lockup_h = lockup_w * lockup.height() as f32 / lockup.width() as f32;
        draw_scaled(
            &mut pm,
            &lockup,
            cx - lockup_w / 2.0,
            cy - lockup_h / 2.0,
            lockup_w,
            0.94,
        );
        let site = "bandito.dev";
        let size = 13.0;
        let site_w = text_width(&fonts.mono, size, site);
        draw_text(
            &mut pm,
            &fonts.mono,
            size,
            cx - site_w / 2.0,
            cy + lockup_h / 2.0 + 34.0,
            site,
            rgba(color::TEXT3, 0.9),
        );
    }
    dither(&mut pm);
    pm
}

/// Adds one level of noise to every pixel, so the soft gradients of the ground do not show bands (a dark 8-bit
/// gradient steps visibly). The same pixels every time.
fn dither(pm: &mut Pixmap) {
    let width = pm.width() as usize;
    for (index, px) in pm.data_mut().chunks_exact_mut(4).enumerate() {
        let (x, y) = ((index % width) as u32, (index / width) as u32);
        let hash = x.wrapping_mul(0x9E37_79B1) ^ y.wrapping_mul(0x85EB_CA6B);
        let hash = (hash ^ (hash >> 15)).wrapping_mul(0x2C1B_3C6D);
        let delta = (hash >> 28) as i16 % 3 - 1;
        for channel in &mut px[..3] {
            *channel = (i16::from(*channel) + delta).clamp(0, 255) as u8;
        }
    }
}

/// One launcher on the dock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LauncherItem {
    pub kind: LauncherKind,
    pub label: String,
}

/// One window in the dock's list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowItem {
    pub id: u32,
    pub title: String,
    pub active: bool,
    /// Minimized.
    pub hidden: bool,
}

/// Who holds the screen's controls, when someone does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Holder {
    Agent,
    User,
}

/// What the pointer can hit on the dock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hit {
    /// The mark at the left: opens the menu.
    Menu,
    Launcher(usize),
    Window(usize),
}

/// What the dock shows. The pictures are a pure function of this.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanelView {
    pub launchers: Vec<LauncherItem>,
    pub windows: Vec<WindowItem>,
    pub hover: Option<Hit>,
    pub time: String,
    pub date: String,
    pub holder: Option<Holder>,
}

/// Where each target is on the dock: `[x, y, width, height]`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PanelLayout {
    pub hits: Vec<(Hit, [f32; 4])>,
}

impl PanelLayout {
    /// What is under the point `x`, `y` of the dock.
    pub fn hit(&self, x: i32, y: i32) -> Option<Hit> {
        let (x, y) = (x as f32, y as f32);
        self.hits
            .iter()
            .find(|(_, r)| x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3])
            .map(|(hit, _)| *hit)
    }
}

const PILL_H: f32 = 34.0;
const GAP: f32 = 8.0;
const SIDE: f32 = 12.0;

/// The dock as a picture `width` pixels wide and `PANEL_HEIGHT` high, and where its targets are. Left to right:
/// the mark that opens the menu, the launchers, the windows, who holds the controls, the clock.
pub fn panel(fonts: &Fonts, width: u32, view: &PanelView) -> (Pixmap, PanelLayout) {
    let mut pm = Pixmap::new(width.max(1), PANEL_HEIGHT).unwrap_or_else(|| Pixmap::new(1, 1).expect("1x1 pixmap"));
    let w = width as f32;
    let h = PANEL_HEIGHT as f32;
    let mut layout = PanelLayout::default();
    let top = (h - PILL_H) / 2.0;

    pm.fill(rgba(color::SURFACE1, 1.0));
    fill_px(&mut pm, 0.0, 0.0, w, 1.0, rgba(color::TEXT, 0.1));

    let hovered = |hit: Hit| view.hover == Some(hit);
    let pill_fill = |hit: Hit| rgba(color::TEXT, if hovered(hit) { 0.11 } else { 0.05 });

    // The mark.
    let mut x = SIDE;
    let mark_rect = [x, top, 44.0, PILL_H];
    fill_rrect(&mut pm, mark_rect, 10.0, pill_fill(Hit::Menu));
    stroke_rrect(&mut pm, mark_rect, 10.0, rgba(color::TEXT, 0.08));
    if let Ok(mark) = Pixmap::decode_png(MARK_PNG) {
        let mark_w = 24.0;
        let mark_h = mark_w * mark.height() as f32 / mark.width() as f32;
        draw_scaled(
            &mut pm,
            &mark,
            x + (44.0 - mark_w) / 2.0,
            top + (PILL_H - mark_h) / 2.0,
            mark_w,
            1.0,
        );
    }
    layout.hits.push((Hit::Menu, mark_rect));
    x += 44.0 + 12.0;

    // The launchers.
    for (index, item) in view.launchers.iter().enumerate() {
        let hit = Hit::Launcher(index);
        let label_w = text_width(&fonts.medium, 13.0, &item.label);
        let pill_w = 12.0 + 18.0 + 8.0 + label_w + 14.0;
        let rect = [x, top, pill_w, PILL_H];
        fill_rrect(&mut pm, rect, 10.0, pill_fill(hit));
        stroke_rrect(
            &mut pm,
            rect,
            10.0,
            rgba(color::TEXT, if hovered(hit) { 0.16 } else { 0.08 }),
        );
        let ink = rgba(color::TEXT, if hovered(hit) { 1.0 } else { 0.86 });
        draw_icon(&mut pm, item.kind, x + 12.0, top + (PILL_H - 18.0) / 2.0, 18.0, ink);
        draw_text(
            &mut pm,
            &fonts.medium,
            13.0,
            x + 12.0 + 18.0 + 8.0,
            top + 22.0,
            &item.label,
            ink,
        );
        layout.hits.push((hit, rect));
        x += pill_w + GAP;
    }
    let left_end = x;

    // Right side, measured first so the window list knows how much room it has.
    let time_size = 15.0;
    let time_w = text_width(&fonts.mono, time_size, &view.time);
    let date_w = text_width(&fonts.regular, 11.0, &view.date);
    let clock_w = time_w.max(date_w);
    let clock_x = w - SIDE - 4.0 - clock_w;
    let mut right_edge = clock_x - 16.0;
    if let Some(holder) = view.holder {
        let (word, dot) = match holder {
            Holder::Agent => ("Agent", color::OK),
            Holder::User => ("You", color::TEXT),
        };
        let word_w = text_width(&fonts.medium, 12.0, word);
        let chip_w = 12.0 + 6.0 + 7.0 + word_w + 12.0;
        let chip_x = right_edge - chip_w;
        if chip_x > left_end + 120.0 {
            let rect = [chip_x, top + 3.0, chip_w, PILL_H - 6.0];
            fill_rrect(&mut pm, rect, 8.0, rgba(color::TEXT, 0.05));
            stroke_rrect(&mut pm, rect, 8.0, rgba(color::TEXT, 0.08));
            fill_circle(&mut pm, chip_x + 12.0 + 3.0, h / 2.0, 3.0, rgba(dot, 1.0));
            draw_text(
                &mut pm,
                &fonts.medium,
                12.0,
                chip_x + 12.0 + 6.0 + 7.0,
                top + 21.0,
                word,
                rgba(color::TEXT2, 1.0),
            );
            right_edge = chip_x - 12.0;
        }
    }
    if clock_x > left_end {
        draw_text(
            &mut pm,
            &fonts.mono,
            time_size,
            clock_x + clock_w - time_w,
            h / 2.0 - 1.0,
            &view.time,
            rgba(color::TEXT, 1.0),
        );
        draw_text(
            &mut pm,
            &fonts.regular,
            11.0,
            clock_x + clock_w - date_w,
            h / 2.0 + 13.0,
            &view.date,
            rgba(color::TEXT3, 1.0),
        );
    }

    // The windows, after a hairline.
    if !view.windows.is_empty() && right_edge - left_end > 120.0 {
        fill_px(
            &mut pm,
            left_end + 2.0,
            top + 6.0,
            1.0,
            PILL_H - 12.0,
            rgba(color::TEXT, 0.1),
        );
        let start = left_end + 14.0;
        let room = right_edge - start;
        let count = view.windows.len() as f32;
        let item_w = ((room - GAP * (count - 1.0)) / count).clamp(40.0, 210.0);
        let mut wx = start;
        for (index, item) in view.windows.iter().enumerate() {
            if wx + item_w > right_edge + 0.5 {
                break;
            }
            let hit = Hit::Window(index);
            let rect = [wx, top, item_w, PILL_H];
            let selected = item.active && !item.hidden;
            let fill = if selected {
                0.09
            } else if hovered(hit) {
                0.07
            } else {
                0.03
            };
            fill_rrect(&mut pm, rect, 10.0, rgba(color::TEXT, fill));
            if selected {
                stroke_rrect(&mut pm, rect, 10.0, rgba(color::TEXT, 0.34));
            } else {
                stroke_rrect(&mut pm, rect, 10.0, rgba(color::TEXT, 0.07));
            }
            let ink = if selected {
                color::TEXT
            } else if item.hidden {
                color::TEXT3
            } else {
                color::TEXT2
            };
            let title = fit_text(&fonts.medium, 13.0, &item.title, item_w - 24.0);
            draw_text(
                &mut pm,
                &fonts.medium,
                13.0,
                wx + 12.0,
                top + 22.0,
                &title,
                rgba(ink, 1.0),
            );
            layout.hits.push((hit, rect));
            wx += item_w + GAP;
        }
    }
    (pm, layout)
}

/// Premultiplied RGBA to the 32-bit `B, G, R, pad` pixels of a 24-bit X screen (little endian). The pictures are
/// opaque, so there is nothing to un-premultiply.
pub fn to_bgrx(pm: &Pixmap) -> Vec<u8> {
    let src = pm.data();
    let mut out = Vec::with_capacity(src.len());
    for px in src.chunks_exact(4) {
        out.extend_from_slice(&[px[2], px[1], px[0], 0]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fonts() -> Fonts {
        Fonts::load().expect("bundled fonts parse")
    }

    fn view() -> PanelView {
        PanelView {
            launchers: vec![
                LauncherItem {
                    kind: LauncherKind::Browser,
                    label: "Browser".into(),
                },
                LauncherItem {
                    kind: LauncherKind::Terminal,
                    label: "Terminal".into(),
                },
                LauncherItem {
                    kind: LauncherKind::Files,
                    label: "Files".into(),
                },
            ],
            windows: vec![
                WindowItem {
                    id: 1,
                    title: "Example Domain - Google Chrome".into(),
                    active: true,
                    hidden: false,
                },
                WindowItem {
                    id: 2,
                    title: "sysro@win-ubuntu: ~".into(),
                    active: false,
                    hidden: false,
                },
            ],
            hover: None,
            time: "14:07".into(),
            date: "Tue 13 Oct".into(),
            holder: Some(Holder::Agent),
        }
    }

    #[test]
    fn bundled_assets_decode() {
        assert!(Fonts::load().is_some());
        assert!(Pixmap::decode_png(MARK_PNG).is_ok());
        assert!(Pixmap::decode_png(LOCKUP_PNG).is_ok());
    }

    #[test]
    fn wallpaper_has_the_screen_size_and_is_opaque_and_dark() {
        let pm = wallpaper(&fonts(), 640, 400);
        assert_eq!((pm.width(), pm.height()), (640, 400));
        assert!(pm.data().chunks_exact(4).all(|p| p[3] == 255));
        // A corner is the dark edge of the ground, the center is lit by the lockup.
        let corner = &pm.data()[0..4];
        assert!(corner[0] < 0x20 && corner[1] < 0x20 && corner[2] < 0x20, "{corner:?}");
        let lit = pm
            .data()
            .chunks_exact(4)
            .filter(|p| p[0] > 0xC0 && p[1] > 0xC0 && p[2] > 0xB0)
            .count();
        assert!(lit > 200, "the lockup is drawn ({lit} light pixels)");
    }

    #[test]
    fn wallpaper_survives_tiny_and_huge_screens() {
        let f = fonts();
        assert_eq!(wallpaper(&f, 1, 1).width(), 1);
        assert_eq!(wallpaper(&f, 320, 240).height(), 240);
        assert_eq!(wallpaper(&f, 2560, 1440).width(), 2560);
    }

    #[test]
    fn dock_lists_mark_launchers_and_windows_in_order_without_overlap() {
        let (pm, layout) = panel(&fonts(), 1280, &view());
        assert_eq!((pm.width(), pm.height()), (1280, PANEL_HEIGHT));
        let hits: Vec<Hit> = layout.hits.iter().map(|(h, _)| *h).collect();
        assert_eq!(
            hits,
            vec![
                Hit::Menu,
                Hit::Launcher(0),
                Hit::Launcher(1),
                Hit::Launcher(2),
                Hit::Window(0),
                Hit::Window(1)
            ]
        );
        for pair in layout.hits.windows(2) {
            let (a, b) = (pair[0].1, pair[1].1);
            assert!(a[0] + a[2] <= b[0], "{a:?} overlaps {b:?}");
        }
        for (_, rect) in &layout.hits {
            assert!(rect[0] + rect[2] <= 1280.0 && rect[1] + rect[3] <= PANEL_HEIGHT as f32);
        }
    }

    #[test]
    fn dock_hit_test_finds_the_target_under_a_point() {
        let (_, layout) = panel(&fonts(), 1280, &view());
        let (hit, rect) = layout.hits[1];
        assert_eq!(layout.hit((rect[0] + 3.0) as i32, 24), Some(hit));
        assert_eq!(layout.hit(1279, 24), None, "the clock is not a button");
        assert_eq!(layout.hit(rect[0] as i32, 1), None, "above the pills");
    }

    #[test]
    fn dock_without_launchers_or_windows_still_draws_the_mark_and_clock() {
        let empty = PanelView {
            launchers: vec![],
            windows: vec![],
            hover: None,
            time: "09:00".into(),
            date: "Mon 1 Jan".into(),
            holder: None,
        };
        let (pm, layout) = panel(&fonts(), 800, &empty);
        assert_eq!(layout.hits.len(), 1);
        assert!(
            pm.data().chunks_exact(4).any(|p| p[0] > 0xE0),
            "the clock text is drawn"
        );
    }

    #[test]
    fn narrow_dock_drops_windows_before_it_overflows() {
        let (_, layout) = panel(&fonts(), 420, &view());
        for (_, rect) in &layout.hits {
            assert!(rect[0] + rect[2] <= 420.0, "{rect:?}");
        }
    }

    #[test]
    fn long_titles_are_cut_with_an_ellipsis_that_fits() {
        let f = fonts();
        let long = "A very long page title that cannot possibly fit into a small dock button".to_string();
        let cut = fit_text(&f.medium, 13.0, &long, 120.0);
        assert!(cut.ends_with('\u{2026}'));
        assert!(text_width(&f.medium, 13.0, &cut) <= 120.0);
        assert_eq!(fit_text(&f.medium, 13.0, "Files", 120.0), "Files");
        assert_eq!(fit_text(&f.medium, 13.0, "x", 0.5), "");
    }

    #[test]
    fn titles_in_other_scripts_do_not_panic() {
        let f = fonts();
        let (pm, _) = panel(
            &f,
            900,
            &PanelView {
                windows: vec![WindowItem {
                    id: 9,
                    title: "设置 設定 설정 \u{1F600} \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}".into(),
                    active: false,
                    hidden: true,
                }],
                ..view()
            },
        );
        assert_eq!(pm.width(), 900);
    }

    #[test]
    fn bgrx_swaps_red_and_blue_and_zeroes_the_pad() {
        let mut pm = Pixmap::new(2, 1).unwrap();
        pm.data_mut().copy_from_slice(&[1, 2, 3, 255, 10, 20, 30, 255]);
        assert_eq!(to_bgrx(&pm), vec![3, 2, 1, 0, 30, 20, 10, 0]);
    }

    #[test]
    fn hover_changes_the_picture() {
        let f = fonts();
        let plain = panel(&f, 800, &view()).0;
        let hover = panel(
            &f,
            800,
            &PanelView {
                hover: Some(Hit::Launcher(0)),
                ..view()
            },
        )
        .0;
        assert_ne!(plain.data(), hover.data());
    }

    /// `DESKTOP_PREVIEW_DIR=/some/folder cargo test --lib desktop::paint::tests::preview -- --ignored` saves the
    /// wallpaper and the dock as PNG files, to look at them while changing the design.
    #[test]
    #[ignore = "writes pictures to DESKTOP_PREVIEW_DIR"]
    fn preview() {
        let Some(dir) = std::env::var_os("DESKTOP_PREVIEW_DIR") else {
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        let f = fonts();
        let mut screen = wallpaper(&f, 1280, 800);
        let (dock, _) = panel(
            &f,
            1280,
            &PanelView {
                hover: Some(Hit::Launcher(1)),
                ..view()
            },
        );
        screen.draw_pixmap(
            0,
            800 - PANEL_HEIGHT as i32,
            dock.as_ref(),
            &PixmapPaint::default(),
            Transform::identity(),
            None,
        );
        screen.save_png(dir.join("preview.png")).unwrap();
    }
}
