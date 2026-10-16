mod client;
mod ensemble;
mod goals;
mod models;
mod protocol;

use tokio::io::{AsyncWriteExt, BufReader};

#[tokio::main(worker_threads = 2)]
async fn main() {
    let engine = match client::Engine::new() {
        Ok(engine) => engine,
        Err(error) => {
            let response = models::Response::new(String::new(), Err(error));
            if let Ok(mut bytes) = serde_json::to_vec(&response) {
                bytes.push(b'\n');
                let _ = tokio::io::stdout().write_all(&bytes).await;
            }
            std::process::exit(1);
        }
    };
    // Stdout belongs exclusively to the NDJSON protocol. No request/key/image
    // payload is logged, including when a pipe disconnects.
    if protocol::serve(
        BufReader::new(tokio::io::stdin()),
        tokio::io::stdout(),
        engine,
    )
    .await
    .is_err()
    {
        std::process::exit(1);
    }
}
