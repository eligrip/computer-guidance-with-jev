// JEV_SYNTHETIC_LIVE=1 cargo test --manifest-path engine/Cargo.toml \
//   live_transport_comparison -- --ignored --nocapture
// Uses only the generated current-command.jpg fixture and synthetic speech.
use super::*;

fn safe_error_flags(error: &reqwest::Error) -> Value {
    use std::error::Error;
    let mut io_kinds = Vec::new();
    let mut source = error.source();
    while let Some(cause) = source {
        if let Some(io) = cause.downcast_ref::<std::io::Error>() {
            io_kinds.push(format!("{:?}", io.kind()));
        }
        source = cause.source();
    }
    json!({"kind":"transport", "timeout":error.is_timeout(), "connect":error.is_connect(),
           "dns":error.is_dns(), "request":error.is_request(), "body":error.is_body(),
           "decode":error.is_decode(), "builder":error.is_builder(), "io_kinds":io_kinds})
}

async fn probe(engine: Engine, key: String, encoded: String, index: usize) -> Value {
    let mut request = fixture_request("guidance");
    request.api_key = key;
    let Operation::Guidance(input) = &mut request.operation else {
        unreachable!()
    };
    input.transcript = "Open the shared album. Now download it.".to_owned();
    input.goal = Some("Open the shared album.".to_owned());
    input.image_jpeg_base64 = encoded;
    let Operation::Guidance(input) = &request.operation else {
        unreachable!()
    };
    let (json, image) = Engine::prepare_guidance(&request, input).unwrap();
    let builder = engine.guidance_request(&request, json, image).unwrap();
    let started = std::time::Instant::now();
    let outcome = match builder.send().await {
        Err(error) => json!({"ok":false,"error":safe_error_flags(&error)}),
        Ok(response) => {
            let version = format!("{:?}", response.version());
            let status = response.status().as_u16();
            if !response.status().is_success() {
                // Never read/print HTTP error bodies or arbitrary header values.
                let retry = response
                    .headers()
                    .get("Retry-After")
                    .and_then(|h| h.to_str().ok())
                    .and_then(|h| retry_delay(h, SystemTime::now()));
                json!({"ok":false,"version":version,"error":{"kind":"http","status":status,"retry_after":retry}})
            } else {
                match response.bytes().await {
                    Err(error) => {
                        json!({"ok":false,"version":version,"error":safe_error_flags(&error)})
                    }
                    Ok(bytes) => {
                        json!({"ok":parse_guidance(&bytes, 0.65, 0.25).is_ok(),"version":version,"status":status})
                    }
                }
            }
        }
    };
    json!({"index":index,"milliseconds":started.elapsed().as_millis(),"outcome":outcome})
}

#[tokio::test]
#[ignore = "Synthetic HTTP-auto vs HTTP/1 comparison; requires JEV_SYNTHETIC_LIVE=1"]
async fn live_transport_comparison() {
    let key = super::command_focus::synthetic_key();
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    let image = std::fs::read(root.join(".build/evals/current-command.jpg"))
        .expect("Generate the synthetic fixture first");
    let encoded = STANDARD.encode(image);
    for mode in ["http_auto", "http1_only"] {
        let mut engine = Engine::new().unwrap();
        let mut builder = Client::builder();
        if mode == "http1_only" {
            builder = builder.http1_only();
        }
        // Construct both explicitly: the production Engine now uses HTTP/1.
        engine.client = builder
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .pool_idle_timeout(Duration::from_secs(90))
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .build()
            .unwrap();
        let mut failed = false;
        // Three sequential calls warm and reuse the connection before a burst.
        for index in 0..3 {
            let result = probe(engine.clone(), key.clone(), encoded.clone(), index).await;
            println!(
                "{}",
                json!({"mode":mode,"phase":"sequential","call":result})
            );
            if result["outcome"]["ok"] != true {
                if result["outcome"]["error"]["kind"] == "http" {
                    return;
                }
                failed = true;
                break;
            }
        }
        if failed {
            continue;
        }
        let phase_started = std::time::Instant::now();
        // Bounded sustained reuse can expose connection failures absent in one burst.
        for batch in 0..20 {
            if phase_started.elapsed() >= Duration::from_secs(5) {
                break;
            }
            let mut tasks = tokio::task::JoinSet::new();
            for index in 0..6 {
                tasks.spawn(probe(engine.clone(), key.clone(), encoded.clone(), index));
            }
            let mut http_error = false;
            let mut failed = false;
            let mut results = Vec::new();
            while let Some(result) = tasks.join_next().await {
                let result = result.unwrap();
                http_error |= result["outcome"]["error"]["kind"] == "http";
                failed |= result["outcome"]["ok"] != true;
                results.push(result);
            }
            println!(
                "{}",
                json!({"mode":mode,"phase":"concurrent","batch":batch,
                                   "elapsed_ms":phase_started.elapsed().as_millis(),"calls":results})
            );
            // A provider status error ends the experiment instead of trying another
            // client during a possible cooldown. Transport errors end that profile.
            if http_error {
                return;
            }
            if failed {
                break;
            }
        }
    }
}
