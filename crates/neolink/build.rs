//! Embeds the icon and version information in the Windows executable. Nothing happens elsewhere
//! (a check of the Windows target from another system skips it: it needs the Windows SDK's tools).
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../../Resources/AppIcon.ico");
    #[cfg(windows)]
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        // The GNU toolchain needs windres for this; a contributor's build without it still runs (no icon).
        if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("gnu") && std::process::Command::new("windres").arg("--version").output().is_err() {
            println!("cargo:warning=windres not found: this build has no icon or version information");
            return;
        }
        let mut resource = winresource::WindowsResource::new();
        resource.set_icon("../../Resources/AppIcon.ico");
        resource.set("ProductName", "NeoLink");
        resource.set("FileDescription", "NeoLink");
        resource.set("OriginalFilename", "NeoLink.exe");
        resource.compile().expect("the Windows resources (icon, version) compile");
    }
}
