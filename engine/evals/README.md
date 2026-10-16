# Box consensus experiment

## Current utterance and stale goals

`python3 engine/evals/utterance_focus.py --check` validates invented conversation
fixtures offline. After building the release engine and generating
`make_command_fixture.py`, use `--live` to check exact current-utterance selections
and Box targets. `--cases` accepts a comma-separated subset; the first service
error stops the run. No microphone or real screen is used, and results are saved
under ignored `.build/evals`.

Eight focused cases passed on October 16: an unpunctuated new task, a pronoun
substep, a correction, a generic help follow-up, unrelated chatter, cancellation,
and two next-step Boxes. Generic help and chatter retained the prior goal;
actionable changes selected new verbatim text. The first cold call took 2,621 ms;
the remaining calls took 126–221 ms. These small fixtures verify context handling,
not end-to-end microphone or desktop response time.

## Sustained guidance comparison

```sh
cargo build --manifest-path engine/Cargo.toml --release --locked
python3 engine/evals/sustained_guidance.py --live --seconds 18
python3 Tests/sustained-guidance.test.py -v
```

The opt-in live evaluation alternates three generated screens every two seconds
through the production Rust pipe protocol. It compares the prior two-call/100 ms
cadence, six single calls/35 ms, and two concurrent three-call batches/35 ms. Each
profile also checks the latest source-span goal every 500 ms. It reports operation
and HTTP throughput, latency percentiles, center-hit accuracy, per-control IoU,
stale-screen responses, and time to the first correct answer after each synthetic
scene change. These measurements exclude native capture, speech and presentation.
The optional `--profiles fast_talking` stress profile runs goal checks every 120 ms
to exercise the call load allowed during changing speech; it repeats the synthetic
command rather than simulating an actual microphone/recognizer stream.
`faster_six` and `faster_three` exercise the current 20 ms Fast cadence with goal
checks every 120 ms. `faster_eight` raises only the target concurrency to eight
for comparison; the app retains six to leave room for goals and draining work.

The default is 15 seconds per profile, with a maximum of 1,000 attempted HTTP
calls per profile and no unbounded work queue. `--profiles fast_single,fast_three`
selects a subset. Any provider error stops further dispatch, drains existing
requests and ends the experiment; there are no implicit retries. The complete
synthetic-only report is written to ignored `.build/evals/sustained-guidance.json`
(override with `--output`). The credential goes only through the engine's stdin.
The offline scheduler tests need neither a key nor Pillow and exercise concurrency
bounds, draining on rate limits, old-scene exclusion and three-sample accounting.
For a sustained resilience measurement, `--recover-transport` allows fresh checks
after an isolated connection failure, using the app's bounded 250 ms–2 s backoff.
Failures remain in the report and produce a nonzero exit code even if the run
finishes. HTTP errors still stop the experiment; this option does not bypass
provider rate limits or replay failed calls automatically.

### Measurements on October 16, 2026

The default HTTP/2 connection reproduced a correlated disconnect: three warmed
sequential calls succeeded, then all six concurrent calls failed together after
70–72 ms. HTTP/1.1 completed that same short comparison. Longer runs still had
isolated connection failures, so HTTP/1.1 is failure isolation, not a guarantee
of an error-free network. The transport comparison is reproducible with:

```sh
python3 engine/evals/make_command_fixture.py
JEV_SYNTHETIC_LIVE=1 cargo test --manifest-path engine/Cargo.toml live_transport_comparison -- --ignored --nocapture
```

All rows below use HTTP/1.1. Rates include drain time and recovery pauses. The
first row completed without recovery; later rows explicitly enabled bounded
transport recovery and recorded every failure. No HTTP rate-limit/overload
response occurred in these runs; local synthetic HTTP tests cover those paths.

| Target configuration | Goal interval | Duration | Target operations/s | Successful HTTP calls/s | Target median / p95 ms | Failed HTTP / attempted |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Two single calls, 100 ms | 500 ms | 18 s | 9.18 | 11.17 | 150 / 269 | 0 / 202 |
| Six single calls, 35 ms | 500 ms | 18 s | 25.78 | 27.77 | 151 / 234 | 4 / 507 |
| Two three-call batches, 35 ms | 500 ms | 18 s | 10.42 | 33.40 | 172 / 263 | 3 / 609 |
| Six single calls, 20 ms | 120 ms | 18 s | 34.97 | 42.99 | 150 / 210 | 2 / 784 |
| Two three-call batches, 20 ms | 120 ms | 18 s | 9.11 | 34.71 | 171 / 271 | 9 / 634 |
| Eight single calls, 20 ms | 120 ms | 12 s | 30.52 | 36.59 | 145 / 265 | 12 / 458 |

The final six-call/20 ms run centered all 636 completed boxes on the intended
control and selected all 146 goals correctly. The three-call/20 ms run centered
all 164 completed boxes correctly and selected all 127 goals correctly; partially
failed batches are included in failure counts, not accuracy denominators. Their
mean IoUs for wide button / toolbar / Dock were 0.904 / 0.800 / 0.547 for single
and 0.905 / 0.814 / 0.534 for three-call averaging. This shows mixed boundary
precision, not a general accuracy advantage for three calls.

First correct answer after a synthetic scene change ranged from 135–260 ms in
the final single-call run and 155–1,810 ms in the three-call run. The latter had
one long scheduling/response gap; these are host-and-engine observations, not a
guarantee of provider latency or native overlay response time. The fixtures are
simple and the runs short. Eight-call concurrency performed worse in this sample,
so Fast keeps six targets and two goals, with the measured 20 ms dispatch floor.

## Current-command and concurrency checks

Generate the synthetic three-button screen, then explicitly opt into provider calls:

```sh
python3 engine/evals/make_command_fixture.py
JEV_SYNTHETIC_LIVE=1 cargo test --manifest-path engine/Cargo.toml live_current_commands -- --ignored --nocapture
JEV_SYNTHETIC_LIVE=1 cargo test --manifest-path engine/Cargo.toml live_fast_guidance_throughput -- --ignored --nocapture
```

The first test checks 15 exact-source goal transitions and, when the generated
image exists, two Boxes that must advance beyond the saved earlier action. The
second makes 20 calls across two rounds of a two-target baseline and a simultaneous
six-target/two-goal burst. Both load the ignored local key without printing it and
use synthetic inputs only. These tests are ignored by ordinary offline test runs.

On October 15, 2026, all 15 goal cases and both Box cases passed. The two eight-call
bursts completed in 231 ms and 180 ms with zero errors; the warm two-target baseline
completed in 153 ms. These are short provider bursts, not sustained call rates or
desktop interaction latency. Capture, speech, screen changes, network conditions,
and provider rate limits still affect the application.

## Consensus evaluation

Build the Rust engine, install Pillow in the Python environment if needed, and run:

```sh
cargo build --manifest-path engine/Cargo.toml --locked
python3 engine/evals/box_consensus.py --live
```

The script uses only generated images and synthetic speech. It loads the existing
`TYPESAFE_API_KEY` environment variable or ignored `.env.local`, sends credentials
through the engine's stdin, and prints synthetic metrics. It does not capture a
screen, microphone, notes, or application content. `--fixture` and `--rounds` allow
bounded reruns. Default evaluation is 37 provider calls, including one discarded
warmup. A failed call stops the run and reports its safe engine error; completed
rounds are printed immediately, including abstentions.

The three requests in a group use the same image, JSON state, questions, and model.
Each answer must pass presence/confidence gates. All three boxes are averaged only
when every pair has IoU at least 0.5. Otherwise the strongest agreeing pair is used
(sum of confidence, then IoU, then earlier sample indices). No agreeing pair means
abstention. Confidence weights the edges and reported probabilities; agreement does
not multiply probabilities or imply independent evidence. Valid raw coordinates
and probabilities are retained even for excluded samples. Invalid coordinates are
represented as null.

## Synthetic measurements, 2026-10-15

`jev-1.14.0`, presence threshold 0.65, confidence threshold 0.25. IoU compares each
returned box with the known drawn control boundary. Sample 0 is the first dispatched
answer within each group, not necessarily the first response to finish. A separate
single-call baseline uses the same fixture. Reported times are whole-operation
latencies through the persistent Rust engine; individual HTTP times are not exposed.

| Generated control | Completed rounds | Single median ms | Group median ms | Single mean IoU | Sample 0 mean IoU | Fused mean IoU | Maximum edge spread |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Wide button, 1000×650 | 3 | 155.5 | 281.2 | 0.9135 | 0.9135 | 0.9135 | 0 px |
| Small toolbar button, 1200×750 | 3 | 121.8 | 125.0 | 0.7857 | 0.7381 | 0.8105 | 12 px |
| Dock-like icon, 1200×750 | 1 | 163.9 | 214.6 | 0.4314 | 0.4314 | 0.4314 | 0 px |

The wide button and Dock icon produced identical coordinates in every completed
group. Toolbar sample IoUs were `[0.7857, 0.9231, 0.8889]`,
`[0.7143, 0.6314, 0.8889]`, and `[0.7143, 0.8889, 0.7857]`; fused IoUs were
`0.8875`, `0.7446`, and `0.7992`. Minimum pairwise toolbar IoU was 0.7111, so all
three samples contributed in every completed group. Every individual and fused
box center was inside the intended control. The icon result's low boundary IoU
therefore does not mean it selected the wrong icon.

Two earlier Dock runs stopped before a complete comparison: one returned an error
without an HTTP status (its safe message was not recorded), and one returned the
engine's fixed connection-failure message, also without an HTTP status or retry
delay. Neither is included in the accuracy or latency table. The final bounded
Dock rerun completed; the script now identifies failed requests and records prior
completed rounds explicitly.

These small synthetic results show useful variation in one fixture and no benefit
in two. They do not establish a general accuracy improvement or a reliable latency
estimate for real desktop sessions. Keep the mode experimental and inspect replay
samples before choosing a default.
