//! PDF tabs on macOS: Apple's own `PDFView` (as the Swift app's document tabs use), placed over the
//! document pane. AppKit views live on the main thread, so the workspace (built on the render thread)
//! only says where the view should be; the main thread creates, moves, hides and commands the views.

/// What the workspace wants from the PDF views.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PdfRequest {
    /// The PDF to show and its frame in window points, top-left origin; `None` hides every view.
    pub shown: Option<(String, [f64; 4])>,
    /// The PDFs that still have tabs (views of closed tabs are released).
    pub open: Vec<String>,
}

/// A toolbar command for the shown PDF.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PdfCommand {
    PreviousPage,
    NextPage,
    ZoomOut,
    ZoomIn,
    Fit,
}

#[cfg(target_os = "macos")]
mod host {
    use super::*;
    use std::collections::HashMap;
    use objc2::rc::Retained;
    use objc2::{AnyThread, MainThreadMarker};
    use objc2_app_kit::{NSColor, NSView};
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString, NSURL};
    use objc2_pdf_kit::{PDFDisplayMode, PDFDocument, PDFView};

    pub struct PdfHost {
        views: HashMap<String, Retained<PDFView>>,
        shown: Option<String>,
    }

    impl PdfHost {
        pub fn new() -> PdfHost {
            PdfHost { views: HashMap::new(), shown: None }
        }

        /// Shows, moves or hides the views as `request` says, inside `window`'s content view.
        /// Returns a message if a PDF could not be opened.
        pub fn apply(&mut self, window: &winit::window::Window, request: &PdfRequest) -> Option<String> {
            use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
            let main = MainThreadMarker::new()?;
            let handle = window.window_handle().ok()?;
            let RawWindowHandle::AppKit(handle) = handle.as_raw() else { return None };
            let parent: &NSView = unsafe { handle.ns_view.cast::<NSView>().as_ref() };
            let mut problem = None;
            // Views of closed tabs go.
            self.views.retain(|path, view| {
                let keep = request.open.contains(path);
                if !keep {
                    view.removeFromSuperview();
                }
                keep
            });
            let wanted = request.shown.as_ref().map(|(path, _)| path.clone());
            if self.shown != wanted {
                if let Some(view) = self.shown.as_ref().and_then(|path| self.views.get(path)) {
                    unsafe { view.setHidden(true) };
                }
                self.shown = wanted.clone();
            }
            let Some((path, frame)) = &request.shown else { return None };
            if !self.views.contains_key(path) {
                match open(main, path) {
                    Some(view) => {
                        unsafe { parent.addSubview(&view) };
                        self.views.insert(path.clone(), view);
                    }
                    None => {
                        problem = Some("This PDF could not be opened.".to_string());
                        return problem;
                    }
                }
            }
            let view = &self.views[path];
            // The content view's coordinates start at its bottom left unless it is flipped.
            let bounds = parent.bounds();
            let y = if parent.isFlipped() { frame[1] } else { bounds.size.height - frame[1] - frame[3] };
            let rect = NSRect::new(NSPoint::new(frame[0], y), NSSize::new(frame[2].max(1.0), frame[3].max(1.0)));
            unsafe {
                if view.frame() != rect {
                    view.setFrame(rect);
                }
                if view.isHidden() {
                    view.setHidden(false);
                }
            }
            problem
        }

        pub fn command(&self, command: PdfCommand) {
            let Some(view) = self.shown.as_ref().and_then(|path| self.views.get(path)) else { return };
            unsafe {
                match command {
                    PdfCommand::PreviousPage => view.goToPreviousPage(None),
                    PdfCommand::NextPage => view.goToNextPage(None),
                    PdfCommand::ZoomOut => view.zoomOut(None),
                    PdfCommand::ZoomIn => view.zoomIn(None),
                    PdfCommand::Fit => view.setAutoScales(true),
                }
            }
        }

        /// "Page 2 of 10" for the shown PDF.
        pub fn page_label(&self) -> Option<String> {
            let view = self.shown.as_ref().and_then(|path| self.views.get(path))?;
            unsafe {
                let document = view.document()?;
                let count = document.pageCount();
                let index = view.currentPage().map(|page| document.indexForPage(&page) + 1).unwrap_or(1);
                Some(format!("Page {index} of {count}"))
            }
        }
    }

    fn open(main: MainThreadMarker, path: &str) -> Option<Retained<PDFView>> {
        unsafe {
            let url = NSURL::fileURLWithPath(&NSString::from_str(path));
            let document = PDFDocument::initWithURL(PDFDocument::alloc(), &url)?;
            let view = PDFView::initWithFrame(main.alloc::<PDFView>(), NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(100.0, 100.0)));
            // As the Swift app: the editor's background, one continuous column, fitted to the width.
            view.setBackgroundColor(&NSColor::colorWithSRGBRed_green_blue_alpha(0x18 as f64 / 255.0, 0x18 as f64 / 255.0, 0x18 as f64 / 255.0, 1.0));
            view.setDisplayMode(PDFDisplayMode::SinglePageContinuous);
            view.setAutoScales(true);
            view.setDocument(Some(&document));
            Some(view)
        }
    }
}

#[cfg(target_os = "macos")]
pub use host::PdfHost;

/// Elsewhere PDFs open in the system's viewer instead (no embedded view yet).
#[cfg(not(target_os = "macos"))]
pub struct PdfHost;

#[cfg(not(target_os = "macos"))]
impl PdfHost {
    pub fn new() -> PdfHost {
        PdfHost
    }

    pub fn apply(&mut self, _window: &winit::window::Window, _request: &PdfRequest) -> Option<String> {
        None
    }

    pub fn command(&self, _command: PdfCommand) {}

    pub fn page_label(&self) -> Option<String> {
        None
    }
}

/// Whether `path` is a PDF by its name.
pub fn is_pdf(path: &str) -> bool {
    std::path::Path::new(path).extension().and_then(|extension| extension.to_str()).is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"))
}
