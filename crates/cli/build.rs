include!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../build_support/build_stamp.rs"
));

fn main() {
    let stamp = emit_build_stamp();
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../../build_support/build_stamp.rs");
    println!("cargo:rerun-if-env-changed=LEOPARDWM_BUILD_STAMP_EPOCH");

    let version = format!("{}.{}", env!("CARGO_PKG_VERSION"), stamp.number);
    let mut res = winresource::WindowsResource::new();
    res.set_icon("../../assets/leopardwm.ico");
    res.set("FileDescription", "LeopardWM command-line interface");
    res.set("FileVersion", &version);
    res.set("ProductVersion", &version);
    res.set("Comments", &format!("Built {}", stamp.timestamp));
    res.compile().expect("Failed to compile Windows resources");
}
