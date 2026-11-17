//! Embeds the icon and version information in the Windows executable. Nothing happens elsewhere
//! (a check of the Windows target from another system skips it: it needs the Windows SDK's tools).
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../../Resources/AppIcon.ico");
    #[cfg(windows)]
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut resource = winresource::WindowsResource::new();
        resource.set_icon("../../Resources/AppIcon.ico");
        resource.set("ProductName", "NeoLink");
        resource.set("FileDescription", "NeoLink");
        resource.set("OriginalFilename", "NeoLink.exe");
        resource.compile().expect("the Windows resources (icon, version) compile");
    }
}
