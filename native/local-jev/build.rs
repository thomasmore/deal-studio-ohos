use std::{env, fs, path::PathBuf};
fn main() {
    assert!(
        !(env::var_os("JEV_BUNDLE_DIR").is_some() && env::var_os("LAYA_BUNDLE_DIR").is_some()),
        "select one embedded model with JEV_BUNDLE_DIR or LAYA_BUNDLE_DIR"
    );
    println!("cargo:rerun-if-env-changed=JEV_BUNDLE_DIR");
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("assets.rs");
    let mut code = String::new();
    for (name, file) in [
        ("CONFIG", "config.json"),
        ("TOKENIZER", "tokenizer.json"),
        ("WEIGHTS", "model.safetensors"),
        ("MANIFEST", "manifest.json"),
    ] {
        if let Some(dir) = env::var_os("JEV_BUNDLE_DIR") {
            let path =
                fs::canonicalize(PathBuf::from(dir).join(file)).expect("missing bundle asset");
            println!("cargo:rerun-if-changed={}", path.display());
            code += &format!("pub const {name}: &[u8] = include_bytes!({:?});\n", path);
        } else {
            code += &format!("pub const {name}: &[u8] = &[];\n");
        }
    }
    println!("cargo:rerun-if-env-changed=LAYA_BUNDLE_DIR");
    for (name, file) in [
        ("LAYA_CONFIG", "laya-config.json"),
        ("LAYA_TOKENIZER", "tokenizer.json"),
        ("LAYA_WEIGHTS", "model.gguf"),
        ("LAYA_MANIFEST", "laya-manifest.json"),
    ] {
        if let Some(dir) = env::var_os("LAYA_BUNDLE_DIR") {
            let path = fs::canonicalize(PathBuf::from(dir).join(file)).expect("missing Laya asset");
            println!("cargo:rerun-if-changed={}", path.display());
            code += &format!("pub const {name}: &[u8] = include_bytes!({:?});\n", path);
        } else {
            code += &format!("pub const {name}: &[u8] = &[];\n");
        }
    }
    fs::write(out, code).unwrap();
}
