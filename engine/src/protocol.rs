use std::{io, sync::Arc};

use serde::Deserialize;
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt},
    sync::{Mutex, Semaphore},
    task::JoinSet,
};

use crate::{client::Engine, models::*};

enum Line {
    End,
    Data(Vec<u8>),
    TooLarge,
}

/// Unlike read_line(), this never allocates beyond the configured frame limit.
/// Oversized lines are drained so the next valid JSON request still works.
async fn read_limited_line<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    limit: usize,
) -> io::Result<Line> {
    let mut line = Vec::new();
    let mut too_large = false;
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return Ok(if too_large {
                Line::TooLarge
            } else if line.is_empty() {
                Line::End
            } else {
                Line::Data(line)
            });
        }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let count = newline.map_or(chunk.len(), |index| index + 1);
        let data_count = newline.unwrap_or(count);
        if !too_large {
            if line.len() + data_count > limit {
                too_large = true;
                line.clear();
            } else {
                line.extend_from_slice(&chunk[..data_count]);
            }
        }
        reader.consume(count);
        if newline.is_some() {
            return Ok(if too_large {
                Line::TooLarge
            } else {
                Line::Data(line)
            });
        }
    }
}

fn parse_request(line: &[u8]) -> Result<Request, Response> {
    serde_json::from_slice(line).map_err(|_| {
        #[derive(Deserialize)]
        struct Envelope {
            id: String,
        }
        let id = serde_json::from_slice::<Envelope>(line)
            .map(|value| value.id)
            .unwrap_or_default();
        Response::new(
            id,
            Err(EngineError::local(
                "Invalid engine request. Check the operation and input fields.",
            )),
        )
    })
}

async fn write_response<W: AsyncWrite + Unpin>(
    writer: &Mutex<W>,
    response: Response,
) -> io::Result<()> {
    let mut data = serde_json::to_vec(&response).map_err(io::Error::other)?;
    data.push(b'\n');
    let mut writer = writer.lock().await;
    writer.write_all(&data).await?;
    writer.flush().await
}

pub async fn serve<R, W>(mut reader: R, writer: W, engine: Engine) -> io::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let writer = Arc::new(Mutex::new(writer));
    let concurrency = Arc::new(Semaphore::new(2));
    let mut tasks = JoinSet::new();
    loop {
        while tasks.try_join_next().is_some() {}
        match read_limited_line(&mut reader, MAX_REQUEST_BYTES).await? {
            Line::End => break,
            Line::TooLarge => {
                write_response(
                    &writer,
                    Response::new(
                        String::new(),
                        Err(EngineError::local(
                            "Engine request exceeds the 24 MiB limit.",
                        )),
                    ),
                )
                .await?;
            }
            Line::Data(line) => {
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let request = match parse_request(&line) {
                    Ok(value) => value,
                    Err(response) => {
                        write_response(&writer, response).await?;
                        continue;
                    }
                };
                // Acquire before spawning so neither task count nor queued
                // request memory grows with an over-eager native caller.
                let permit = concurrency
                    .clone()
                    .acquire_owned()
                    .await
                    .map_err(io::Error::other)?;
                let engine = engine.clone();
                let writer = writer.clone();
                tasks.spawn(async move {
                    let _permit = permit;
                    let result = engine.execute(&request).await;
                    write_response(&writer, Response::new(request.id, result)).await
                });
            }
        }
    }
    while let Some(result) = tasks.join_next().await {
        match result {
            Ok(result) => result?,
            Err(_) => return Err(io::Error::other("Engine task stopped unexpectedly.")),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use tokio::io::{AsyncReadExt, BufReader};

    #[tokio::test]
    async fn oversized_line_drains_and_next_line_survives() {
        let input = b"123456789012345\nnext\n";
        let mut reader = BufReader::with_capacity(3, &input[..]);
        assert!(matches!(
            read_limited_line(&mut reader, 8).await.unwrap(),
            Line::TooLarge
        ));
        match read_limited_line(&mut reader, 8).await.unwrap() {
            Line::Data(value) => assert_eq!(value, b"next"),
            _ => panic!("Expected the following complete frame"),
        }
        assert!(matches!(
            read_limited_line(&mut reader, 8).await.unwrap(),
            Line::End
        ));
    }

    #[test]
    fn invalid_operation_keeps_id_but_never_echoes_payload() {
        let response = parse_request(br#"{"id":"bad","op":"unknown","api_key":"secret-do-not-echo","input":{"transcript":"private speech"}}"#)
            .err().unwrap();
        let encoded = serde_json::to_string(&response).unwrap();
        assert_eq!(response.id, "bad");
        assert!(!encoded.contains("secret-do-not-echo"));
        assert!(!encoded.contains("private speech"));
    }

    #[tokio::test]
    async fn persistent_protocol_recovers_after_invalid_input_and_flushes_each_result() {
        let (client, server) = tokio::io::duplex(8_192);
        let (read, write) = tokio::io::split(server);
        let engine = Engine::new().unwrap();
        let running = tokio::spawn(serve(BufReader::new(read), write, engine));
        let (client_read, mut client_write) = tokio::io::split(client);
        let mut client_read = BufReader::new(client_read);
        client_write.write_all(b"not-json\n").await.unwrap();
        let mut first = String::new();
        client_read.read_line(&mut first).await.unwrap();
        let failure: Value = serde_json::from_str(&first).unwrap();
        assert_eq!(failure["ok"], false);

        let mut request = json!({
            "id": "goal-1", "op": "goal", "api_key": "fake", "model": "jev-1.14.0",
            "minimum_presence": 0.65, "minimum_confidence": 0.25,
            "input": { "transcript": "", "previous_goal": "Save a photo" }
        });
        // Empty speech returns the previous anchor without any network call.
        for id in ["goal-1", "goal-2"] {
            request["id"] = json!(id);
            let mut line = serde_json::to_vec(&request).unwrap();
            line.push(b'\n');
            client_write.write_all(&line).await.unwrap();
            let mut response = String::new();
            client_read.read_line(&mut response).await.unwrap();
            let value: Value = serde_json::from_str(&response).unwrap();
            assert_eq!(value["id"], id);
            assert_eq!(value["ok"], true);
            assert_eq!(value["result"]["goal"], "Save a photo");
        }
        client_write.shutdown().await.unwrap();
        let mut rest = Vec::new();
        client_read.read_to_end(&mut rest).await.unwrap();
        assert!(rest.is_empty());
        running.await.unwrap().unwrap();
    }
}
