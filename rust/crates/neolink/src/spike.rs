//! Stack spike content: the same 160 x 50 changing text grid as `spikes/gpui`.

use crate::frame::Content;
use crate::render::Scene;
use crate::text::TextSystem;

pub const ROWS: usize = 50;
pub const COLUMNS: usize = 160;

pub fn row_text(row: usize, counter: u64) -> String {
    let mut text = String::with_capacity(COLUMNS);
    let mut seed = (row as u64).wrapping_mul(0x9E3779B97F4A7C15) ^ counter.wrapping_mul(0xD1B54A32D192ED03);
    for _ in 0..COLUMNS {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let c = b"abcdefghijklmnopqrstuvwxyz    (){}[];=+-_0123456789"[(seed >> 33) as usize % 51];
        text.push(c as char);
    }
    text
}

pub struct SpikeGrid {
    pub rows: Vec<String>,
    pub counter: u64,
    pub motion: bool,
}

impl SpikeGrid {
    pub fn new(motion: bool) -> SpikeGrid {
        SpikeGrid { rows: (0..ROWS).map(|row| row_text(row, 0)).collect(), counter: 0, motion }
    }

    pub fn change(&mut self) {
        self.counter += 1;
        let row = (self.counter as usize * 7) % ROWS;
        self.rows[row] = row_text(row, self.counter);
    }
}

impl Content for SpikeGrid {
    fn build(&mut self, scene: &mut Scene, text: &mut TextSystem, queue: &wgpu::Queue, _size: (u32, u32), _frame_time: f64, _period: f64) -> bool {
        if self.motion {
            self.counter += 1;
            let row = (self.counter as usize) % ROWS;
            self.rows[row] = row_text(row, self.counter);
        }
        let cell = text.cell;
        for (row, line) in self.rows.iter().enumerate() {
            let baseline = row as f32 * cell.height + cell.baseline;
            for (column, character) in line.chars().enumerate() {
                if let Some(glyph) = text.cell_glyph(queue, character, false, false) {
                    scene.glyph(glyph.sprite, column as f32 * cell.width + glyph.x as f32, baseline + glyph.y as f32, [0xd0, 0xd0, 0xd0, 0xff]);
                }
            }
        }
        self.motion
    }
}
