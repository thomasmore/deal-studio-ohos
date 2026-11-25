use local_jev::{shared_experimental::Ranker, uncertain, MAX_BYTES};
use serde_json::{json, Value};
use std::{
    io::{self, BufRead, Read, Write},
    path::Path,
    time::Instant,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let started = Instant::now();
    let dir = std::env::args()
        .nth(1)
        .ok_or("usage: local-jev-shared BUNDLE_DIR")?;
    let engine = Ranker::load(Path::new(&dir))?;
    let mut out = io::BufWriter::new(io::stdout().lock());
    writeln!(
        out,
        "{}",
        json!({"kind":"ready","ready":true,"protocol":1,
        "startup_ms":started.elapsed().as_secs_f64()*1000.0})
    )?;
    out.flush()?;
    let mut input = io::stdin().lock();
    let limit = MAX_BYTES + 512;
    let mut line = Vec::new();
    loop {
        line.clear();
        if input
            .by_ref()
            .take((limit + 2) as u64)
            .read_until(b'\n', &mut line)?
            == 0
        {
            break;
        }
        let newline = line.last() == Some(&b'\n');
        let length = line.len() - usize::from(newline);
        let started = Instant::now();
        let reply = if length > limit {
            if !newline {
                input.skip_until(b'\n')?;
            }
            uncertain("request_too_large")
        } else if let Ok(frame) = serde_json::from_slice::<Value>(&line[..length]) {
            if frame["id"]
                .as_str()
                .is_some_and(|id| !id.is_empty() && id.len() <= 80)
                && frame["request"].is_object()
            {
                let response = engine.decisions(&frame["request"].to_string());
                json!({"kind":"result","id":frame["id"],"response":response,
                    "inference_ms":started.elapsed().as_secs_f64()*1000.0})
            } else {
                uncertain("invalid_frame")
            }
        } else {
            uncertain("invalid_frame")
        };
        writeln!(out, "{reply}")?;
        out.flush()?;
    }
    Ok(())
}
