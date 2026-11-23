use local_jev::{uncertain, Engine, MAX_BYTES};
use std::{
    io::{self, BufRead, Read},
    path::Path,
};
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut dir = None;
    let mut scores = false;
    let mut stream = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--bundle" if i + 1 < args.len() => {
                i += 1;
                dir = Some(args[i].clone());
            }
            "--scores" => scores = true,
            "--stream" => stream = true,
            _ => {
                eprintln!("usage: local-jev [--bundle DIR] [--scores] [--stream]");
                std::process::exit(2);
            }
        }
        i += 1;
    }
    let engine = match dir {
        Some(dir) => Engine::from_dir(Path::new(&dir)),
        None => Engine::embedded(),
    };
    let predict = |body: &str| match &engine {
        Ok(e) if scores => e
            .scores(body)
            .unwrap_or_else(|_| uncertain("unsupported_or_failed_inference")),
        Ok(e) => e.predict(body),
        Err(_) => uncertain("model_unavailable"),
    };
    let stdin = io::stdin();
    if stream {
        let mut input = stdin.lock();
        loop {
            let mut bytes = Vec::new();
            match input
                .by_ref()
                .take((MAX_BYTES + 2) as u64)
                .read_until(b'\n', &mut bytes)
            {
                Ok(0) => break,
                Err(_) => {
                    println!("{}", uncertain("input_read_failed"));
                    std::process::exit(1);
                }
                Ok(_) => {}
            }
            let has_newline = bytes.last() == Some(&b'\n');
            let body_len = bytes.len() - usize::from(has_newline);
            if body_len > MAX_BYTES {
                println!("{}", uncertain("request_too_large"));
                if !has_newline && input.skip_until(b'\n').is_err() {
                    std::process::exit(1);
                }
                continue;
            }
            bytes.truncate(body_len);
            match std::str::from_utf8(&bytes) {
                Ok(body) => println!("{}", predict(body)),
                Err(_) => println!("{}", uncertain("invalid_utf8")),
            }
        }
    } else {
        let mut body = String::new();
        if stdin
            .take((MAX_BYTES + 1) as u64)
            .read_to_string(&mut body)
            .is_err()
        {
            println!("{}", uncertain("invalid_utf8"));
        } else {
            println!("{}", predict(&body));
        }
    }
}
