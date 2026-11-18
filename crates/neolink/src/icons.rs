//! Icons. The Swift app draws SF Symbols; on macOS the same symbols are rasterised here into coverage
//! masks (tinted when drawn), so the icons are the identical artwork. Elsewhere there are no SF Symbols:
//! a stand-in glyph from the interface font is used and the look differs (listed in PLAN.md).

/// A rasterised icon: 8-bit coverage, `width` x `height` device pixels.
pub struct IconBitmap {
    pub width: u32,
    pub height: u32,
    pub coverage: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum IconWeight {
    Light,
    Regular,
    Medium,
    Semibold,
}

/// The stand-in for a symbol where SF Symbols do not exist.
pub fn fallback_glyph(name: &str) -> &'static str {
    match name {
        "plus" => "+",
        "xmark" | "xmark.circle.fill" => "\u{00d7}",
        "chevron.right" => "\u{203a}",
        "chevron.down" => "\u{2304}",
        "terminal" => ">_",
        "folder" | "folder.fill" | "folder.badge.gearshape" => "\u{25a1}",
        "sparkles" => "\u{2726}",
        "magnifyingglass" | "doc.text.magnifyingglass" => "\u{2315}",
        "arrow.triangle.branch" => "\u{2442}",
        "sidebar.left" => "\u{25e7}",
        "sidebar.right" => "\u{25e8}",
        "arrow.clockwise" => "\u{21bb}",
        "rectangle.compress.vertical" => "\u{2912}",
        "line.3.horizontal.decrease.circle" => "\u{2261}",
        "play.fill" => "\u{25b6}",
        "square.and.arrow.down" => "\u{2913}",
        "exclamationmark.circle" => "!",
        "curlybraces" => "{}",
        "bolt.fill" => "\u{26a1}",
        "network" => "\u{25ce}",
        "gearshape" => "\u{2699}",
        "photo" => "\u{25a3}",
        "checkmark" | "checkmark.circle" => "\u{2713}",
        "doc.text" => "\u{2630}",
        "command" => "\u{2318}",
        _ => "\u{25a4}",
    }
}

#[cfg(target_os = "macos")]
pub fn rasterize(name: &str, points: f32, weight: IconWeight, scale: f32) -> Option<IconBitmap> {
    use objc2::rc::autoreleasepool;
    use objc2::AnyThread;
    use objc2_app_kit::{NSBitmapImageRep, NSDeviceRGBColorSpace, NSGraphicsContext, NSImage, NSImageSymbolConfiguration};
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};

    autoreleasepool(|_| unsafe {
        let symbol = NSImage::imageWithSystemSymbolName_accessibilityDescription(&NSString::from_str(name), None)?;
        let weight = match weight {
            IconWeight::Light => objc2_app_kit::NSFontWeightLight,
            IconWeight::Regular => objc2_app_kit::NSFontWeightRegular,
            IconWeight::Medium => objc2_app_kit::NSFontWeightMedium,
            IconWeight::Semibold => objc2_app_kit::NSFontWeightSemibold,
        };
        let configuration = NSImageSymbolConfiguration::configurationWithPointSize_weight(points as f64, weight);
        let image = symbol.imageWithSymbolConfiguration(&configuration)?;
        let size = image.size();
        let (width, height) = ((size.width * scale as f64).ceil().max(1.0) as isize, (size.height * scale as f64).ceil().max(1.0) as isize);
        let bitmap = NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
            NSBitmapImageRep::alloc(),
            std::ptr::null_mut(),
            width,
            height,
            8,
            4,
            true,
            false,
            NSDeviceRGBColorSpace,
            0,
            0,
        )?;
        // Draw in points: the bitmap is `scale` pixels per point.
        bitmap.setSize(NSSize { width: width as f64 / scale as f64, height: height as f64 / scale as f64 });
        let context = NSGraphicsContext::graphicsContextWithBitmapImageRep(&bitmap)?;
        NSGraphicsContext::saveGraphicsState_class();
        NSGraphicsContext::setCurrentContext(Some(&context));
        image.drawInRect(NSRect { origin: NSPoint { x: 0.0, y: 0.0 }, size: NSSize { width: size.width, height: size.height } });
        context.flushGraphics();
        NSGraphicsContext::restoreGraphicsState_class();
        let data = bitmap.bitmapData();
        if data.is_null() {
            return None;
        }
        let row_bytes = bitmap.bytesPerRow() as usize;
        let (width, height) = (width as usize, height as usize);
        let mut coverage = Vec::with_capacity(width * height);
        for row in 0..height {
            let line = std::slice::from_raw_parts(data.add(row * row_bytes), width * 4);
            coverage.extend(line.chunks_exact(4).map(|pixel| pixel[3]));
        }
        Some(IconBitmap { width: width as u32, height: height as u32, coverage })
    })
}

#[cfg(not(target_os = "macos"))]
pub fn rasterize(_name: &str, _points: f32, _weight: IconWeight, _scale: f32) -> Option<IconBitmap> {
    None
}
