// Explicitly opt-in synthetic provider evaluation. No screen or user text is read.
// python3 engine/evals/make_command_fixture.py
// JEV_SYNTHETIC_LIVE=1 cargo test --manifest-path engine/Cargo.toml \
//   live_current_commands -- --ignored --nocapture
// Replace live_current_commands with live_fast_guidance_throughput for 20 calls.
use super::*;

#[tokio::test]
#[ignore = "Makes synthetic TypeSafe calls; requires JEV_SYNTHETIC_LIVE=1"]
async fn live_current_commands() {
    assert_eq!(std::env::var("JEV_SYNTHETIC_LIVE").as_deref(), Ok("1"));
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    let api_key = synthetic_key();
    let cases: Vec<Value> = serde_json::from_str(include_str!("command_focus_cases.json")).unwrap();
    let engine = Engine::new().unwrap();
    let mut failures = Vec::new();
    for case in &cases {
        let mut request = fixture_request("goal");
        request.api_key = api_key.clone();
        let Operation::Goal(input) = &mut request.operation else {
            unreachable!()
        };
        input.transcript = case["speech"].as_str().unwrap().to_owned();
        input.previous_goal = case["previous"].as_str().map(str::to_owned);
        let started = std::time::Instant::now();
        let result = engine
            .execute(&request)
            .await
            .expect("Synthetic TypeSafe request failed");
        let ResultValue::Goal { goal } = result else {
            unreachable!()
        };
        let expected = case["expected"].as_str();
        let passed = goal.as_deref() == expected;
        println!(
            "{}",
            json!({"case":case["name"], "passed":passed, "goal":goal, "milliseconds":started.elapsed().as_millis()})
        );
        if !passed {
            failures.push(case["name"].as_str().unwrap().to_owned());
        }
    }

    // A known generated fixture is optional, so this test also works without Pillow.
    let image_path = root.join(".build/evals/current-command.jpg");
    if let Ok(image) = std::fs::read(image_path) {
        for (name, latest, target_x) in [
            ("box_download_substep", "Now download it.", 0.5),
            ("box_back_substep", "Go back.", 0.8),
        ] {
            let mut request = fixture_request("guidance");
            request.api_key = api_key.clone();
            let Operation::Guidance(input) = &mut request.operation else {
                unreachable!()
            };
            input.transcript = format!("Open the shared album. {latest}");
            input.goal = Some("Open the shared album.".to_owned());
            input.image_jpeg_base64 = STANDARD.encode(&image);
            let started = std::time::Instant::now();
            let ResultValue::Guidance(result) = engine
                .execute(&request)
                .await
                .expect("Synthetic Box call failed")
            else {
                unreachable!()
            };
            let passed = result.r#box.is_some_and(|b| {
                let x = (b.left + b.right) / 2.0;
                let y = (b.top + b.bottom) / 2.0;
                (x - target_x).abs() < 0.12 && y > 0.45 && y < 0.75
            });
            println!(
                "{}",
                json!({"case":name, "passed":passed, "box":result.r#box, "milliseconds":started.elapsed().as_millis()})
            );
            if !passed {
                failures.push(name.to_owned());
            }
        }
    }
    assert!(
        failures.is_empty(),
        "Synthetic semantic failures: {failures:?}"
    );
}

fn synthetic_key() -> String {
    assert_eq!(std::env::var("JEV_SYNTHETIC_LIVE").as_deref(), Ok("1"));
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    std::env::var("TYPESAFE_API_KEY")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            let contents = std::fs::read_to_string(root.join(".env.local")).ok()?;
            contents.lines().find_map(|line| {
                let (name, value) = line.split_once('=')?;
                matches!(name.trim(), "TYPESAFE_API_KEY" | "export TYPESAFE_API_KEY")
                    .then(|| value.trim().trim_matches(['\'', '"']).to_owned())
            })
        })
        .expect("Configure a local TypeSafe key before the opt-in synthetic test")
}

#[tokio::test]
#[ignore = "Makes 20 synthetic TypeSafe calls; requires JEV_SYNTHETIC_LIVE=1"]
async fn live_fast_guidance_throughput() {
    let api_key = synthetic_key();
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    let image = std::fs::read(root.join(".build/evals/current-command.jpg"))
        .expect("Generate the known synthetic button fixture first");
    let encoded = STANDARD.encode(image);
    let engine = Engine::new().unwrap();
    for round in 1..=2 {
        for (label, target_count, goal_count) in [
            ("two_target_baseline", 2, 0),
            ("six_targets_two_goals", 6, 2),
        ] {
            let batch_started = std::time::Instant::now();
            let mut tasks = tokio::task::JoinSet::new();
            for index in 0..target_count + goal_count {
                let op = if index < target_count {
                    "guidance"
                } else {
                    "goal"
                };
                let mut request = fixture_request(op);
                request.api_key = api_key.clone();
                match &mut request.operation {
                    Operation::Guidance(input) => {
                        input.transcript = "Open the shared album. Now download it.".to_owned();
                        input.goal = Some("Open the shared album.".to_owned());
                        input.image_jpeg_base64 = encoded.clone();
                    }
                    Operation::Goal(input) => {
                        input.transcript = "Open the shared album. Now download it.".to_owned();
                        input.previous_goal = Some("Open the shared album.".to_owned());
                    }
                }
                let client = engine.clone();
                tasks.spawn(async move {
                    let start = std::time::Instant::now();
                    let result = client.execute(&request).await;
                    (index, op, start.elapsed().as_millis(), result)
                });
            }
            let mut observations = Vec::new();
            let mut errors = 0;
            while let Some(completed) = tasks.join_next().await {
                let (index, op, duration, result) = completed.unwrap();
                if result.is_err() {
                    errors += 1;
                }
                observations.push(json!({"index":index,"op":op,"milliseconds":duration,"ok":result.is_ok(),"error":result.err()}));
            }
            observations.sort_by_key(|value| value["index"].as_u64().unwrap());
            let elapsed = batch_started.elapsed();
            println!(
                "{}",
                json!({"case":label,"round":round,"wall_ms":elapsed.as_millis(),"completed_calls":target_count+goal_count-errors,"errors":errors,"calls_per_second":(target_count+goal_count-errors) as f64 / elapsed.as_secs_f64(),"calls":observations})
            );
            assert_eq!(
                errors, 0,
                "Provider errors stop the throughput run; no implicit retry"
            );
        }
    }
}
