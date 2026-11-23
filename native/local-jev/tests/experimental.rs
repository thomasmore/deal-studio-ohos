use local_jev::{experimental_decisions, uncertain};
use serde_json::{json, Value};

fn request() -> String {
    json!({"state":"An expense log", "questions":{
        "part":{"type":"choice","instructions":"Choose a section","criteria":{"a":"log","b":"timer"}},
        "live":{"type":"noul","instructions":"Needs live data?"}
    }}).to_string()
}
fn scores() -> Value {
    json!({"answers":{},"scores":{
        "part":{"type":"choice","logits":{"a":1000.,"b":999.}},
        "live":{"type":"noul","logits":{"false":2.,"true":-2.}}
    },"local":{"status":"uncertain","reason":"laya_not_human_calibrated",
        "truncation":{"part":{"truncated":true}}}})
}
#[test]
fn experimental_answers_keep_scores_and_warnings() {
    let raw = scores();
    let answer = experimental_decisions(raw.clone(), &request());
    assert_eq!(answer["answers"]["part"]["choice"], "a");
    assert!(answer["answers"]["live"]["noul"].as_f64().unwrap() < 0.02);
    let p = &answer["answers"]["part"]["probabilities"];
    assert!((p["a"].as_f64().unwrap() + p["b"].as_f64().unwrap() - 1.).abs() < 1e-12);
    assert_eq!(answer["scores"], raw["scores"]);
    assert_eq!(answer["local"]["truncation"], raw["local"]["truncation"]);
    assert_eq!(answer["local"]["diagnostic"], true);
    assert_eq!(answer["local"]["calibrated"], false);
    assert_eq!(answer["local"]["productionAllowed"], false);
    assert_eq!(
        answer["local"]["productionReason"],
        "laya_not_human_calibrated"
    );
}
#[test]
fn invalid_or_partial_scores_never_answer() {
    for invalid in [Value::Null, json!("NaN"), json!({}), json!(true)] {
        let mut raw = scores();
        raw["scores"]["part"]["logits"]["a"] = invalid;
        assert_eq!(
            experimental_decisions(raw, &request())["answers"],
            json!({})
        );
    }
    let mut raw = scores();
    raw["scores"].as_object_mut().unwrap().remove("part");
    assert_eq!(
        experimental_decisions(raw, &request())["answers"],
        json!({})
    );
    let mut raw = scores();
    raw["scores"]["part"]["logits"] = json!({"wrong":1.,"b":2.});
    assert_eq!(
        experimental_decisions(raw, &request())["answers"],
        json!({})
    );
    let mut raw = scores();
    raw["scores"]["part"]["type"] = json!("noul");
    assert_eq!(
        experimental_decisions(raw, &request())["answers"],
        json!({})
    );
    assert_eq!(
        experimental_decisions(scores(), "invalid")["answers"],
        json!({})
    );
    assert_eq!(
        experimental_decisions(uncertain("option_token_budget"), &request()),
        uncertain("option_token_budget")
    );
}
#[test]
fn singleton_and_ties_are_deterministic() {
    let request = json!({"state":"A request", "questions":{
        "one":{"type":"choice","instructions":"Only candidate","criteria":{"a":"log"}},
        "tie":{"type":"choice","instructions":"Tied candidates","criteria":{"a":"log","b":"timer"}}
    }})
    .to_string();
    let raw = json!({"scores":{
        "one":{"type":"choice","logits":{"a":0.}},
        "tie":{"type":"choice","logits":{"b":0.,"a":0.}}
    },"local":{"reason":"laya_not_human_calibrated"}});
    let answer = experimental_decisions(raw, &request);
    assert_eq!(answer["answers"]["one"]["choice"], "a");
    assert_eq!(answer["answers"]["one"]["probabilities"]["a"], 1.);
    assert_eq!(answer["answers"]["tie"]["choice"], "a");
}
#[test]
fn regular_prediction_does_not_enable_experimental_answers() {
    let request = request();
    unsafe {
        let pointer = local_jev::local_jev_predict(request.as_ptr(), request.len());
        let text = std::ffi::CStr::from_ptr(pointer).to_str().unwrap();
        let value: Value = serde_json::from_str(text).unwrap();
        assert_eq!(value["answers"], json!({}));
        local_jev::local_jev_free(pointer);
    }
}
