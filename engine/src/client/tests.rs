use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};

fn fixture_request(op: &str) -> Request {
    let input = if op == "guidance" {
        json!({
            "transcript": "Sarah sent me a photo. I want to save it.", "goal": null,
            "notes": "", "browser_context": null, "accessibility_context": null,
            "image_jpeg_base64": STANDARD.encode([0xff, 0xd8, 0xff, 0xd9])
        })
    } else {
        json!({ "transcript": "Sarah sent me a photo. I want to save it.", "previous_goal": null })
    };
    serde_json::from_value(json!({
        "id": "fixture", "op": op, "api_key": "fake-test-key", "model": "jev-1.14.0",
        "minimum_presence": 0.65, "minimum_confidence": 0.25, "input": input
    }))
    .unwrap()
}

fn guidance_answer(presence: f64, confidence: f64) -> Value {
    json!({ "answers": {
        "target": { "type": "box", "box": { "top": 0.1, "bottom": 0.2, "left": 0.3, "right": 0.4 }, "confidence": confidence },
        "target_present": { "type": "noul", "noul": presence }
    }})
}

fn goal_answer(choice: &str, changed: f64) -> Value {
    json!({ "answers": {
        "goal": { "type": "choice", "choice": choice, "confidence": 0.8 },
        "goal_changed": { "type": "noul", "noul": changed }
    }})
}

#[test]
fn guidance_partitions_current_request_from_obsolete_history() {
    let mut request = fixture_request("guidance");
    let Operation::Guidance(input) = &mut request.operation else {
        unreachable!()
    };
    let goal = "show me the volunteer roles";
    input.transcript = format!(
        "If the banner looks clipped open branding and change the heading {goal} {goal} which ones are on Saturday"
    );
    input.goal = Some(goal.to_owned());
    let payload = guidance_payload(&request.model, input, "synthetic-image");
    let state = &payload["state"];
    assert_eq!(
        state["current_user_request"],
        format!("{goal} which ones are on Saturday")
    );
    assert!(
        state["earlier_conversation"]
            .as_str()
            .unwrap()
            .contains("branding")
    );
    assert!(
        !state["current_user_request"]
            .as_str()
            .unwrap()
            .contains("branding")
    );
    assert_eq!(
        format!(
            "{}{}",
            state["earlier_conversation"].as_str().unwrap(),
            state["current_user_request"].as_str().unwrap()
        ),
        input.transcript
    );
    assert!(state.get("recent_user_speech").is_none());
    assert_eq!(state["goal_anchor_from_user_speech"], goal);
}

#[test]
fn goal_request_exposes_narrow_latest_clause_to_repair_a_mixed_saved_goal() {
    let mut request = fixture_request("goal");
    let Operation::Goal(input) = &mut request.operation else {
        unreachable!()
    };
    let latest = "can you show me the volunteer roles";
    input.transcript = format!(
        "If the banner looks clipped open branding and change the heading {latest} {latest}"
    );
    input.previous_goal = Some(input.transcript.clone());
    let candidates = goals::candidates(&input.transcript);
    let payload = goal_payload(&request.model, input, &candidates);
    assert_eq!(payload["state"]["latest_spoken_clause"], latest);
    assert_eq!(
        payload["questions"]["goal"]["criteria"]["source_0"]["verbatim_user_words"],
        latest
    );
    assert_eq!(
        parse_goal(
            &serde_json::to_vec(&goal_answer("source_0", 0.95)).unwrap(),
            &candidates,
            input.previous_goal.as_deref()
        )
        .unwrap()
        .as_deref(),
        Some(latest)
    );
}

async fn fixture_server(
    status: u16,
    body: &str,
    extra_headers: &str,
) -> (Engine, JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}/v1/systemone", listener.local_addr().unwrap());
    let response = format!(
        "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{extra_headers}\r\n{body}",
        body.len()
    );
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let request = read_http_request(&mut stream).await;
        stream.write_all(response.as_bytes()).await.unwrap();
        stream.shutdown().await.unwrap();
        request
    });
    let mut engine = Engine::new().unwrap();
    engine.endpoint = endpoint;
    engine.client = Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(5))
        .retry(reqwest::retry::never())
        .build()
        .unwrap();
    (engine, task)
}

async fn read_http_request(stream: &mut tokio::net::TcpStream) -> Vec<u8> {
    let mut request = Vec::new();
    let mut buffer = [0_u8; 4_096];
    let mut expected = None;
    loop {
        let count = stream.read(&mut buffer).await.unwrap();
        assert!(count > 0, "Client disconnected before request completion");
        request.extend_from_slice(&buffer[..count]);
        if expected.is_none() {
            if let Some(index) = request.windows(4).position(|value| value == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&request[..index]);
                let content_length = headers
                    .lines()
                    .find_map(|line| {
                        let (key, value) = line.split_once(':')?;
                        key.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                expected = Some(index + 4 + content_length);
            }
        }
        if expected.is_some_and(|length| request.len() >= length) {
            return request;
        }
    }
}

#[test]
fn presence_and_confidence_gate_the_always_returned_box() {
    let low_presence = serde_json::to_vec(&guidance_answer(0.1, 0.95)).unwrap();
    let result = parse_guidance(&low_presence, 0.65, 0.25).unwrap();
    assert!(result.r#box.is_none());
    assert_eq!(result.presence, 0.1);
    assert_eq!(result.confidence, 0.95);
    let low_confidence = serde_json::to_vec(&guidance_answer(0.99, 0.1)).unwrap();
    assert!(
        parse_guidance(&low_confidence, 0.65, 0.25)
            .unwrap()
            .r#box
            .is_none()
    );
    let good = serde_json::to_vec(&guidance_answer(0.99, 0.95)).unwrap();
    assert!(parse_guidance(&good, 0.65, 0.25).unwrap().r#box.is_some());
}

#[test]
fn unusable_box_geometry_never_becomes_a_visible_target() {
    for (field, value) in [("top", 0.9), ("top", -0.1), ("right", 1.1), ("right", 0.3)] {
        let mut answer = guidance_answer(0.99, 0.95);
        answer["answers"]["target"]["box"][field] = json!(value);
        let result = parse_guidance(&serde_json::to_vec(&answer).unwrap(), 0.65, 0.25).unwrap();
        assert!(result.r#box.is_none());
        assert_eq!(result.presence, 0.99);
        assert_eq!(result.confidence, 0.95);
    }
    assert!(
        !NormalizedBox {
            top: f64::NAN,
            bottom: 0.2,
            left: 0.3,
            right: 0.4
        }
        .is_valid()
    );
}

#[test]
fn absent_or_low_confidence_invalid_boxes_are_ignored_without_error() {
    for (presence, confidence) in [(0.01, 0.95), (0.99, 0.1), (0.01, 0.1)] {
        let mut answer = guidance_answer(presence, confidence);
        answer["answers"]["target"]["box"] = json!({
            "top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0
        });
        let result = parse_guidance(&serde_json::to_vec(&answer).unwrap(), 0.65, 0.25).unwrap();
        assert!(result.r#box.is_none());
        assert_eq!(result.presence, presence);
        assert_eq!(result.confidence, confidence);
    }
}

#[test]
fn malformed_probabilities_and_answer_types_remain_errors() {
    for answer in [
        guidance_answer(2.0, 0.9),
        guidance_answer(0.9, -0.1),
        json!({}),
    ] {
        assert!(parse_guidance(&serde_json::to_vec(&answer).unwrap(), 0.65, 0.25).is_err());
    }
    let mut wrong_type = guidance_answer(0.01, 0.1);
    wrong_type["answers"]["target"]["type"] = json!("choice");
    assert!(parse_guidance(&serde_json::to_vec(&wrong_type).unwrap(), 0.65, 0.25).is_err());

    // Even an abstaining Box cannot smuggle an invalid probability through.
    let mut bad_probability = guidance_answer(0.01, 2.0);
    bad_probability["answers"]["target"]["box"]["bottom"] = json!(0.0);
    let error = parse_guidance(&serde_json::to_vec(&bad_probability).unwrap(), 0.65, 0.25)
        .err()
        .unwrap();
    assert!(error.message.contains("probabilities"));
    let nonfinite = guidance_answer(0.99, 0.95)
        .to_string()
        .replace("0.95", "1e400");
    assert!(parse_guidance(nonfinite.as_bytes(), 0.65, 0.25).is_err());
}

#[test]
fn image_payload_rejects_bad_data_before_network() {
    assert!(decode_jpeg("invalid base64").is_err());
    assert!(decode_jpeg(&STANDARD.encode(b"not jpeg")).is_err());
    assert_eq!(
        decode_jpeg(&STANDARD.encode([0xff, 0xd8, 0xff])).unwrap(),
        [0xff, 0xd8, 0xff]
    );
}

#[test]
fn retry_after_seconds_dates_and_error_redaction() {
    let now = SystemTime::UNIX_EPOCH;
    assert_eq!(retry_delay("2.5", now), Some(2.5));
    assert_eq!(retry_delay("nan", now), None);
    assert_eq!(retry_delay("inf", now), None);
    assert_eq!(
        retry_delay("Thu, 01 Jan 1970 00:01:00 GMT", now),
        Some(60.0)
    );
    assert_eq!(
        retry_delay(
            "Thu, 01 Jan 1970 00:00:00 GMT",
            now + Duration::from_secs(10)
        ),
        Some(0.0)
    );
    assert_eq!(EngineError::http(429, Some(2.0)).status, Some(429));
}

#[test]
fn goal_wire_request_preserves_options_and_rejects_generated_values() {
    let request = fixture_request("goal");
    let Operation::Goal(input) = &request.operation else {
        unreachable!()
    };
    let candidates = goals::candidates(&input.transcript);
    let payload = goal_payload(&request.model, input, &candidates);
    let criteria = payload["questions"]["goal"]["criteria"]
        .as_object()
        .unwrap();
    assert_eq!(criteria.len(), candidates.len() + 1);
    assert!(criteria.contains_key("none"));
    assert!(!criteria.contains_key("keep_previous"));
    assert_eq!(payload["questions"]["goal_changed"]["type"], "noul");
    let good = goal_answer(&candidates[0].id, 0.9);
    assert_eq!(
        parse_goal(&serde_json::to_vec(&good).unwrap(), &candidates, None).unwrap(),
        Some(candidates[0].text.clone())
    );
    let bad = goal_answer("generated text", 0.9);
    assert!(parse_goal(&serde_json::to_vec(&bad).unwrap(), &candidates, None).is_err());
}

#[test]
fn fresh_goal_replaces_old_anchor_while_substeps_and_chatter_keep_it() {
    let previous = "I want to find Jane’s attachment.";
    let speech = format!("{previous} I want to join the Zoom call");
    let candidates = goals::candidates(&speech);
    let changed = serde_json::to_vec(&goal_answer(&candidates[0].id, 0.96)).unwrap();
    assert_eq!(
        parse_goal(&changed, &candidates, Some(previous))
            .unwrap()
            .as_deref(),
        Some("I want to join the Zoom call")
    );
    // The speculative Choice is ignored when the independent judgment says
    // recent speech is just a substep or unrelated conversation.
    for speech in [
        "Where should I click to find that attachment?",
        "It is raining outside.",
    ] {
        let candidates = goals::candidates(speech);
        let unchanged = serde_json::to_vec(&goal_answer(&candidates[0].id, 0.02)).unwrap();
        assert_eq!(
            parse_goal(&unchanged, &candidates, Some(previous))
                .unwrap()
                .as_deref(),
            Some(previous)
        );
        assert_eq!(parse_goal(&unchanged, &candidates, None).unwrap(), None);
    }
    let cancelled = serde_json::to_vec(&goal_answer("none", 0.98)).unwrap();
    assert_eq!(
        parse_goal(&cancelled, &candidates, Some(previous)).unwrap(),
        None
    );
}

#[test]
fn goal_change_probability_is_validated_without_accepting_a_fake_branch() {
    let candidates = goals::candidates("Join the call");
    for probability in [-0.1, 1.1] {
        assert!(
            parse_goal(
                &serde_json::to_vec(&goal_answer("source_0", probability)).unwrap(),
                &candidates,
                Some("old task")
            )
            .is_err()
        );
    }
    let fake_keep = serde_json::to_vec(&goal_answer("keep_previous", 0.99)).unwrap();
    assert!(parse_goal(&fake_keep, &candidates, Some("old task")).is_err());
}

#[tokio::test]
async fn multipart_wire_uses_json_first_image_second_and_key_only_in_header() {
    let (engine, server) = fixture_server(200, &guidance_answer(0.99, 0.95).to_string(), "").await;
    let result = engine.execute(&fixture_request("guidance")).await.unwrap();
    assert!(matches!(
        result,
        ResultValue::Guidance(GuidanceResult { r#box: Some(_), .. })
    ));
    let request = server.await.unwrap();
    let split = request
        .windows(4)
        .position(|value| value == b"\r\n\r\n")
        .unwrap();
    let headers = String::from_utf8_lossy(&request[..split]).to_lowercase();
    let body = String::from_utf8_lossy(&request[split + 4..]);
    assert!(headers.contains("authorization: bearer fake-test-key"));
    assert!(headers.contains("typesafe-danger-zone-images: true"));
    assert!(headers.contains("multipart/form-data; boundary="));
    assert!(!body.contains("fake-test-key"));
    assert!(body.find("name=\"request\"").unwrap() < body.find("name=\"screen-jpeg\"").unwrap());
    let json_start = body.find("\r\n\r\n").unwrap() + 4;
    let json_end = body[json_start..].find("\r\n--").unwrap() + json_start;
    let payload: Value = serde_json::from_str(&body[json_start..json_end]).unwrap();
    assert_eq!(payload["model"], "jev-1.14.0");
    assert_eq!(payload["questions"]["target"]["type"], "box");
    assert!(payload["questions"]["target"].get("criteria").is_none());
    assert_eq!(payload["questions"]["target_present"]["type"], "noul");
    let image_id = payload["state"]["screen"].as_str().unwrap();
    assert_eq!(payload["assets"][image_id]["part"], "screen-jpeg");
}

#[tokio::test]
async fn http_rate_limit_reaches_caller_without_echoed_error_body() {
    let (engine, server) =
        fixture_server(429, "private speech and secret-key", "Retry-After: 2\r\n").await;
    let error = engine
        .execute(&fixture_request("goal"))
        .await
        .err()
        .unwrap();
    assert_eq!(error.status, Some(429));
    assert_eq!(error.retry_after, Some(2.0));
    assert!(!error.message.contains("private speech"));
    assert!(!error.message.contains("secret-key"));
    server.await.unwrap();
}

#[tokio::test]
async fn http_goal_response_copies_exact_unicode_candidate() {
    let (engine, server) =
        fixture_server(200, &goal_answer("source_0", 0.99).to_string(), "").await;
    let mut request = fixture_request("goal");
    let Operation::Goal(input) = &mut request.operation else {
        unreachable!()
    };
    input.transcript = "I want  to save Zoë’s 照片".to_owned();
    let result = engine.execute(&request).await.unwrap();
    assert_eq!(
        result,
        ResultValue::Goal {
            goal: Some("I want  to save Zoë’s 照片".to_owned())
        }
    );
    server.await.unwrap();
}

#[tokio::test]
async fn invalid_config_is_rejected_without_a_request() {
    let engine = Engine::new().unwrap();
    let mut request = fixture_request("goal");
    request.minimum_presence = f64::NAN;
    assert!(engine.execute(&request).await.is_err());
    request.minimum_presence = 0.65;
    request.api_key.clear();
    assert!(engine.execute(&request).await.is_err());
}

#[tokio::test]
async fn protocol_runs_three_requests_at_a_time_and_delivers_all_ids() {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::BufReader;
    tokio::time::timeout(Duration::from_secs(5), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut engine = Engine::new().unwrap();
        engine.endpoint = format!("http://{}/v1/systemone", listener.local_addr().unwrap());
        engine.client = Client::builder().no_proxy().build().unwrap();
        let active = Arc::new(AtomicUsize::new(0));
        let maximum = Arc::new(AtomicUsize::new(0));
        let observed = maximum.clone();
        let server = tokio::spawn(async move {
            let mut tasks = tokio::task::JoinSet::new();
            for _ in 0..6 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let active = active.clone();
                let maximum = maximum.clone();
                tasks.spawn(async move {
                    let _request = read_http_request(&mut stream).await;
                    let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                    maximum.fetch_max(now, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(80)).await;
                    let body = goal_answer("source_0", 0.99).to_string();
                    let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    active.fetch_sub(1, Ordering::SeqCst);
                    stream.write_all(response.as_bytes()).await.unwrap();
                    stream.shutdown().await.unwrap();
                });
            }
            while let Some(result) = tasks.join_next().await { result.unwrap(); }
        });
        let (native, backend) = tokio::io::duplex(16_384);
        let (read, write) = tokio::io::split(backend);
        let running = tokio::spawn(crate::protocol::serve(BufReader::new(read), write, engine));
        let (mut output, mut input) = tokio::io::split(native);
        for index in 0..6 {
            let mut line = serde_json::to_vec(&json!({
                "id": format!("request-{index}"), "op": "goal", "api_key": "fake", "model": "jev-1.14.0",
                "minimum_presence": 0.65, "minimum_confidence": 0.25,
                "input": { "transcript": "Save this photo", "previous_goal": null }
            })).unwrap();
            line.push(b'\n');
            input.write_all(&line).await.unwrap();
        }
        input.shutdown().await.unwrap();
        let mut responses = String::new();
        output.read_to_string(&mut responses).await.unwrap();
        running.await.unwrap().unwrap();
        server.await.unwrap();
        let values: Vec<Value> = responses.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
        assert_eq!(values.len(), 6);
        for index in 0..6 {
            assert!(values.iter().any(|value| value["id"] == format!("request-{index}") && value["ok"] == true));
        }
        assert_eq!(observed.load(Ordering::SeqCst), 3, "Engine allows two guidance calls plus one goal call");
    }).await.expect("Bounded concurrency test timed out");
}
