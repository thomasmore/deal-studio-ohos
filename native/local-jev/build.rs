use std::{
    env, fs,
    path::{Path, PathBuf},
};

fn main() {
    println!("cargo:rerun-if-env-changed=JEV_BUNDLE_DIR");
    println!("cargo:rerun-if-env-changed=LAYA_BUNDLE_DIR");
    let jev = env::var_os("JEV_BUNDLE_DIR").map(PathBuf::from);
    let laya = env::var_os("LAYA_BUNDLE_DIR").map(PathBuf::from);
    assert!(
        !(jev.is_some() && laya.is_some()),
        "select one embedded model with JEV_BUNDLE_DIR or LAYA_BUNDLE_DIR"
    );
    let shared = (jev.is_none() && laya.is_none()).then(|| {
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
            .join("../../tools/vera-playground/models/mmbert-shared-state-q8")
    });

    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("assets.rs");
    let mut code = format!("pub const SHARED_PROFILE: bool = {};\n", shared.is_some());
    write_assets(
        &mut code,
        jev.as_deref(),
        &[
            ("CONFIG", "config.json"),
            ("TOKENIZER", "tokenizer.json"),
            ("WEIGHTS", "model.safetensors"),
            ("MANIFEST", "manifest.json"),
        ],
    );
    write_assets(
        &mut code,
        laya.as_deref(),
        &[
            ("LAYA_CONFIG", "laya-config.json"),
            ("LAYA_TOKENIZER", "tokenizer.json"),
            ("LAYA_WEIGHTS", "model.gguf"),
            ("LAYA_MANIFEST", "laya-manifest.json"),
        ],
    );
    write_assets(
        &mut code,
        shared.as_deref(),
        &[
            ("SHARED_MANIFEST", "model.json"),
            ("SHARED_TOKENIZER", "tokenizer.json"),
            ("SHARED_EMBEDDINGS", "embeddings.q8"),
            ("SHARED_WEIGHTS", "ranker.safetensors"),
        ],
    );
    fs::write(out, code).unwrap();
}

fn write_assets(code: &mut String, dir: Option<&Path>, assets: &[(&str, &str)]) {
    for (name, file) in assets {
        if let Some(dir) = dir {
            let path = dir.join(file);
            let path = fs::canonicalize(&path)
                .unwrap_or_else(|error| panic!("Invalid bundle asset {}: {error}", path.display()));
            println!("cargo:rerun-if-changed={}", path.display());
            code.push_str(&format!(
                "pub const {name}: &[u8] = include_bytes!({path:?});\n"
            ));
        } else {
            code.push_str(&format!("pub const {name}: &[u8] = &[];\n"));
        }
    }
}
