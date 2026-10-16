use super::*;

#[test]
fn monotonic_deadlines_extend_but_never_shorten_and_expire() {
    let now = Instant::now();
    let mut cooldown = ServiceCooldown::default();
    cooldown.record(429, Some(2.0), now);
    cooldown.record(503, Some(0.1), now + Duration::from_millis(50));
    // A successful sibling is not evidence that a shared quota has recovered.
    cooldown.record(200, None, now + Duration::from_millis(100));
    assert_eq!(cooldown.remaining(now), Some((429, 2.0)));
    cooldown.record(529, Some(3.0), now + Duration::from_secs(1));
    assert_eq!(cooldown.remaining(now), Some((529, 4.0)));
    assert_eq!(cooldown.remaining(now + Duration::from_secs(4)), None);
    cooldown.succeeded(cooldown.generation, now + Duration::from_secs(4));
    cooldown.record(429, None, now + Duration::from_secs(5));
    assert_eq!(
        cooldown.remaining(now + Duration::from_secs(5)),
        Some((429, 0.25))
    );
}

#[test]
fn repeated_overload_without_hints_backs_off_until_a_fresh_request_succeeds() {
    let start = Instant::now();
    let mut cooldown = ServiceCooldown::default();
    let mut now = start;
    for expected in [0.25, 0.5, 1.0, 2.0, 2.0] {
        let old_generation = cooldown.generation;
        cooldown.record(529, None, now);
        assert_eq!(cooldown.remaining(now), Some((529, expected)));
        // Neither a success during the cooldown nor a late old sibling after
        // expiration may reset the provider-error streak.
        cooldown.succeeded(cooldown.generation, now);
        now += Duration::from_secs_f64(expected) + Duration::from_millis(1);
        cooldown.succeeded(old_generation, now);
    }
    cooldown.succeeded(cooldown.generation, now);
    cooldown.record(503, None, now);
    assert_eq!(cooldown.remaining(now), Some((503, 0.25)));
}

#[test]
fn retry_hints_use_longest_supported_header_and_invalid_hints_have_fallback() {
    use reqwest::header::{HeaderMap, HeaderValue};
    let now = SystemTime::UNIX_EPOCH;
    let mut headers = HeaderMap::new();
    headers.insert("retry-after", HeaderValue::from_static("2"));
    headers.insert("retry-after-ms", HeaderValue::from_static("3500"));
    assert_eq!(response_retry_delay(&headers, now), Some(3.5));
    headers.insert("retry-after", HeaderValue::from_static("4"));
    assert_eq!(response_retry_delay(&headers, now), Some(4.0));
    for bad in ["NaN", "inf", "-100", "not a number", "1e300"] {
        headers.remove("retry-after");
        headers.insert("retry-after-ms", HeaderValue::from_str(bad).unwrap());
        assert_eq!(response_retry_delay(&headers, now), None);
        headers.remove("retry-after-ms");
        headers.insert("retry-after", HeaderValue::from_str(bad).unwrap());
        assert_eq!(response_retry_delay(&headers, now), None);
    }
    let instant = Instant::now();
    for delay in [None, Some(0.0), Some(-1.0), Some(f64::NAN), Some(f64::MAX)] {
        let mut cooldown = ServiceCooldown::default();
        cooldown.record(529, delay, instant);
        assert_eq!(cooldown.remaining(instant), Some((529, 0.25)));
    }
    let mut cooldown = ServiceCooldown::default();
    cooldown.record(401, Some(500.0), instant);
    assert_eq!(cooldown.remaining(instant), None);
}

async fn wait_for_cooldown(engine: &Engine) {
    tokio::time::timeout(Duration::from_secs(1), async {
        while engine.check_cooldown().is_ok() {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .expect("Fixture should promptly install the shared cooldown");
}

#[tokio::test]
async fn early_429_blocks_refill_before_consensus_finishes_then_allows_fresh_request() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let replies = vec![
            FixtureReply {
                status: 429,
                retry_after: Some(1),
                delay_ms: 30,
                ..FixtureReply::success()
            },
            FixtureReply {
                delay_ms: 250,
                ..FixtureReply::success()
            },
            FixtureReply {
                delay_ms: 450,
                ..FixtureReply::success()
            },
            FixtureReply {
                delay_ms: 0,
                ..FixtureReply::success()
            },
        ];
        let (engine, server, _) = concurrent_fixture_server(replies).await;
        let group_engine = engine.clone();
        let group =
            tokio::spawn(async move { group_engine.execute(&three_sample_request()).await });
        wait_for_cooldown(&engine).await;
        assert!(!group.is_finished(), "The slow siblings are still running");
        let available_before = engine.http_slots.available_permits();
        for op in ["goal", "guidance"] {
            let blocked = engine.execute(&fixture_request(op)).await.unwrap_err();
            assert_eq!(blocked.status, Some(429));
            assert!(
                blocked
                    .retry_after
                    .is_some_and(|delay| delay > 0.0 && delay <= 1.0)
            );
        }
        assert!(
            engine.http_slots.available_permits() >= available_before,
            "Cooldown refusals must not occupy HTTP permits"
        );
        let error = group.await.unwrap().unwrap_err();
        assert_eq!(error.completed_calls, Some(2));
        assert_eq!(
            engine.cooldown.lock().unwrap().failures,
            1,
            "Successful old siblings cannot reset the backoff streak"
        );
        let remaining = error.retry_after.unwrap();
        assert!(
            remaining > 0.0 && remaining < 0.9,
            "Consensus must report remaining time, not restart the full delay"
        );
        tokio::time::sleep(Duration::from_secs_f64(remaining) + Duration::from_millis(15)).await;
        assert!(engine.execute(&fixture_request("goal")).await.is_ok());
        assert_eq!(
            engine.cooldown.lock().unwrap().failures,
            0,
            "Fresh post-cooldown success demonstrates recovery"
        );
        // The two blocked requests never reached the server. No failed request
        // was retried; only the explicitly submitted fresh request resumed.
        assert_eq!(server.await.unwrap().len(), 4);
    })
    .await
    .expect("Cooldown/refill fixture timed out");
}

#[tokio::test]
async fn caller_already_waiting_for_a_permit_rechecks_new_cooldown() {
    use std::{future::Future, task::Poll};
    tokio::time::timeout(Duration::from_secs(3), async {
        let (mut engine, server) = fixture_server(429, "ignored", "retry-after-ms: 600\r\n").await;
        engine.http_slots = Arc::new(Semaphore::new(1));
        let held = engine.http_slots.acquire().await.unwrap();
        let request = fixture_request("goal");
        let mut queued = Box::pin(engine.execute(&request));
        // Poll until it has passed initial admission and is waiting for a slot.
        std::future::poll_fn(|cx| {
            assert!(queued.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        // A separate in-flight response installs the cooldown before this queued
        // call gets its permit. This is the same update performed by send().
        engine
            .cooldown
            .lock()
            .unwrap()
            .record(429, Some(0.6), Instant::now());
        drop(held);
        let blocked = queued.await.unwrap_err();
        assert_eq!(blocked.status, Some(429));
        assert_eq!(engine.http_slots.available_permits(), 1);
        // No TCP request was made by the queued caller. After expiration, a fresh
        // request reaches the server and receives its independent 600ms hint.
        tokio::time::sleep(Duration::from_millis(620)).await;
        let actual = engine.execute(&fixture_request("goal")).await.unwrap_err();
        assert_eq!(actual.status, Some(429));
        assert!(
            actual
                .retry_after
                .is_some_and(|delay| delay > 0.4 && delay <= 0.6)
        );
        assert!(!server.await.unwrap().is_empty());
    })
    .await
    .expect("Queued permit fixture timed out");
}

#[tokio::test]
async fn slow_successful_siblings_do_not_restart_an_expired_cooldown() {
    tokio::time::timeout(Duration::from_secs(3), async {
        let replies = vec![
            FixtureReply {
                status: 529,
                retry_after: None,
                delay_ms: 10,
                ..FixtureReply::success()
            },
            FixtureReply {
                delay_ms: 400,
                ..FixtureReply::success()
            },
            FixtureReply {
                delay_ms: 400,
                ..FixtureReply::success()
            },
        ];
        let (engine, server, _) = concurrent_fixture_server(replies).await;
        let error = engine.execute(&three_sample_request()).await.unwrap_err();
        assert_eq!(error.status, Some(529));
        assert_eq!(error.completed_calls, Some(2));
        assert_eq!(error.retry_after, Some(0.0));
        assert!(engine.check_cooldown().is_ok());
        assert_eq!(server.await.unwrap().len(), 3);
    })
    .await
    .expect("Elapsed consensus cooldown fixture timed out");
}
