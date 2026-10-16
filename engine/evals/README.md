# Box consensus experiment

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
