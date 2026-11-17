//! Stack spike: GPUI drawing a 160 x 50 text grid that changes on a timer.
//!
//! Prints `CHANGE <time>` when the model changes; the patched renderer prints
//! `PRESENTED <submitted> <presented>` for every frame. `scripts/analyze-spike.py` pairs them.
//!
//! SPIKE_MODE=sparse (a change every 90-250 ms), dense (every 33 ms), motion (every frame).

use gpui::{
    div, prelude::*, px, rgb, size, App, Bounds, Context, SharedString, Window, WindowBounds, WindowOptions,
};
use gpui_platform::application;
use std::time::Duration;

#[link(name = "QuartzCore", kind = "framework")]
unsafe extern "C" {
    fn CACurrentMediaTime() -> f64;
}

fn now() -> f64 {
    unsafe { CACurrentMediaTime() }
}

const ROWS: usize = 50;
const COLUMNS: usize = 160;

struct Grid {
    rows: Vec<SharedString>,
    counter: u64,
    motion: bool,
}

fn row_text(row: usize, counter: u64) -> SharedString {
    let mut text = String::with_capacity(COLUMNS);
    let mut seed = (row as u64).wrapping_mul(0x9E3779B97F4A7C15) ^ counter.wrapping_mul(0xD1B54A32D192ED03);
    for _ in 0..COLUMNS {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let c = b"abcdefghijklmnopqrstuvwxyz    (){}[];=+-_0123456789"[(seed >> 33) as usize % 51];
        text.push(c as char);
    }
    text.into()
}

impl Render for Grid {
    fn render(&mut self, window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        if self.motion {
            // Every frame changes one row, like a scroll would.
            self.counter += 1;
            let row = (self.counter as usize) % ROWS;
            self.rows[row] = row_text(row, self.counter);
            window.request_animation_frame();
        }
        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(0x181818))
            .text_color(rgb(0xd0d0d0))
            .font_family("Menlo")
            .text_size(px(12.0))
            .line_height(px(16.0))
            .children(self.rows.iter().cloned().map(|row| div().h(px(16.0)).child(row)))
    }
}

fn main() {
    let mode = std::env::var("SPIKE_MODE").unwrap_or_else(|_| "sparse".into());
    let seconds: f64 = std::env::var("SPIKE_SECONDS").ok().and_then(|s| s.parse().ok()).unwrap_or(8.0);
    application().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(1200.0), px(820.0)), cx);
        let mode_for_view = mode.clone();
        cx.open_window(
            WindowOptions {
                window_bounds: Some(if std::env::var("NEOLINK_WINDOW").as_deref() == Ok("fullscreen") {
                    WindowBounds::Fullscreen(bounds)
                } else {
                    WindowBounds::Windowed(bounds)
                }),
                ..Default::default()
            },
            move |_, cx| {
                cx.new(|cx: &mut Context<Grid>| {
                    let mode = mode_for_view.clone();
                    if mode != "motion" && mode != "idle" {
                        cx.spawn(async move |this, cx| {
                            let mut seed: u64 = 0x2545F4914F6CDD1D;
                            cx.background_executor().timer(Duration::from_millis(3000)).await;
                            loop {
                                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                                let wait = if mode == "dense" {
                                    33_000 + (seed >> 40) % 700
                                } else {
                                    90_000 + (seed >> 40) % 160_000
                                };
                                cx.background_executor().timer(Duration::from_micros(wait)).await;
                                let updated = this.update(cx, |grid, cx| {
                                    grid.counter += 1;
                                    let row = (grid.counter as usize * 7) % ROWS;
                                    grid.rows[row] = row_text(row, grid.counter);
                                    eprintln!("CHANGE {:.6}", now());
                                    cx.notify();
                                });
                                if updated.is_err() {
                                    break;
                                }
                            }
                        })
                        .detach();
                    }
                    Grid { rows: (0..ROWS).map(|row| row_text(row, 0)).collect(), counter: 0, motion: mode_for_view == "motion" }
                })
            },
        )
        .unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            cx.background_executor().timer(Duration::from_secs_f64(seconds + 3.0)).await;
            eprintln!("END {:.6}", now());
            let _ = cx.update(|cx| cx.quit());
        })
        .detach();
    });
}
