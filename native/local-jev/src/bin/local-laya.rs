use local_jev::{laya::Engine, uncertain, MAX_BYTES};
use std::{
    io::{self, BufRead, Read, Write},
    path::Path,
};
fn main() {
    let startup = std::time::Instant::now();
    let args: Vec<_> = std::env::args().skip(1).collect();
    let mut scores = false;
    let mut diagnostic = false;
    let mut experimental = false;
    let mut batch_questions = false;
    let mut report_batches = false;
    let mut stream = false;
    let mut framed = false;
    let mut bundle = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--scores" => scores = true,
            "--experimental-decisions" => experimental = true,
            "--diagnostic-scores" => {
                scores = true;
                diagnostic = true;
            }
            "--batch-questions" => batch_questions = true,
            "--report-batches" => report_batches = true,
            "--stream" => stream = true,
            "--framed" => {
                stream = true;
                framed = true;
            }
            "--bundle" if index + 1 < args.len() => {
                index += 1;
                bundle = Some(&args[index]);
            }
            _ => {
                eprintln!(
                    "usage: local-laya [--bundle DIR] [--scores | --diagnostic-scores | --experimental-decisions] [--stream | --framed] [--batch-questions [--report-batches]]"
                );
                std::process::exit(2);
            }
        }
        index += 1;
    }
    let model = bundle.map_or_else(Engine::embedded, |path| Engine::from_dir(Path::new(path)));
    if let Err(reason) = &model {
        eprintln!("{reason}");
    }
    let predict = |body: &str| match &model {
        Ok(model) if experimental => match model.diagnostic_scores(body) {
            Ok(raw) => local_jev::experimental_decisions(raw, body),
            Err(reason) => uncertain(&reason),
        },
        Ok(model) if scores && batch_questions => {
            let mut lengths = Vec::new();
            let result =
                model.batched_scores(body, diagnostic, report_batches.then_some(&mut lengths));
            if report_batches {
                eprintln!(
                    "{}",
                    serde_json::json!({"kind":"question_batches","lengths":lengths})
                );
            }
            result.unwrap_or_else(|reason| uncertain(&reason))
        }
        Ok(model) if scores => (if diagnostic {
            model.diagnostic_scores(body)
        } else {
            model.scores(body)
        })
        .unwrap_or_else(|reason| uncertain(&reason)),
        Ok(model) => model.predict(body),
        Err(_) => uncertain("laya_model_unavailable"),
    };
    if stream {
        if framed {
            println!(
                "{}",
                serde_json::json!({"kind":"ready","protocol":1,"ready":model.is_ok(),"startup_ms":startup.elapsed().as_secs_f64()*1000.})
            );
            io::stdout().flush().unwrap();
        }
        let frame_max = MAX_BYTES + if framed { 512 } else { 0 };
        let mut input = io::stdin().lock();
        loop {
            let mut bytes = Vec::new();
            match input
                .by_ref()
                .take((frame_max + 2) as u64)
                .read_until(b'\n', &mut bytes)
            {
                Ok(0) => break,
                Err(_) => {
                    println!("{}", uncertain("input_read_failed"));
                    std::process::exit(1);
                }
                Ok(_) => {}
            }
            let newline = bytes.last() == Some(&b'\n');
            let length = bytes.len() - usize::from(newline);
            let result = if length > frame_max {
                if !newline && input.skip_until(b'\n').is_err() {
                    std::process::exit(1);
                }
                uncertain("request_too_large")
            } else {
                bytes.truncate(length);
                match std::str::from_utf8(&bytes) {
                    Ok(body) if framed => {
                        let frame: Result<serde_json::Value, _> = serde_json::from_str(body);
                        match frame {
                            Ok(frame)
                                if frame["id"]
                                    .as_str()
                                    .is_some_and(|id| !id.is_empty() && id.len() <= 80)
                                    && frame.get("request").is_some() =>
                            {
                                let started = std::time::Instant::now();
                                let response = predict(&frame["request"].to_string());
                                serde_json::json!({"kind":"result","id":frame["id"],"response":response,"inference_ms":started.elapsed().as_secs_f64()*1000.})
                            }
                            _ => {
                                serde_json::json!({"kind":"protocol_error","reason":"invalid_frame"})
                            }
                        }
                    }
                    Ok(body) => predict(body),
                    Err(_) => uncertain("invalid_utf8"),
                }
            };
            println!("{result}");
            io::stdout().flush().unwrap();
        }
        return;
    }
    let mut body = String::new();
    let response = if io::stdin()
        .take((MAX_BYTES + 1) as u64)
        .read_to_string(&mut body)
        .is_err()
    {
        uncertain("invalid_utf8")
    } else if body.len() > MAX_BYTES {
        uncertain("request_too_large")
    } else {
        predict(&body)
    };
    println!("{response}");
}
