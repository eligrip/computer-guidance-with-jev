use super::*;

fn combine(samples: Vec<GuidanceSample>) -> GuidanceResult {
    super::combine(samples, 0.65, 0.25)
}

fn rectangle(left: f64, right: f64) -> NormalizedBox {
    NormalizedBox {
        top: 0.25,
        bottom: 0.75,
        left,
        right,
    }
}

fn sample(box_value: Option<NormalizedBox>, confidence: f64, presence: f64) -> GuidanceSample {
    GuidanceSample {
        activity: 1.0,
        r#box: box_value,
        confidence,
        presence,
    }
}

fn close(actual: f64, expected: f64) {
    assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
}

#[test]
fn iou_is_symmetric_and_requires_valid_geometry() {
    let a = rectangle(0.0, 0.75);
    let b = rectangle(0.25, 1.0);
    close(intersection_over_union(a, a), 1.0);
    close(intersection_over_union(a, b), 0.5);
    close(intersection_over_union(b, a), 0.5);
    close(
        intersection_over_union(rectangle(0.0, 0.2), rectangle(0.8, 1.0)),
        0.0,
    );
    close(intersection_over_union(rectangle(0.8, 0.2), b), 0.0);
}

#[test]
fn all_agreeing_boxes_use_confidence_weighted_edges_and_uninflated_scores() {
    let result = combine(vec![
        sample(Some(rectangle(0.1, 0.5)), 0.6, 0.7),
        sample(Some(rectangle(0.12, 0.52)), 0.8, 0.9),
        sample(Some(rectangle(0.14, 0.54)), 1.0, 1.0),
    ]);
    let output = result.r#box.unwrap();
    close(output.left, (0.1 * 0.6 + 0.12 * 0.8 + 0.14) / 2.4);
    close(output.right, (0.5 * 0.6 + 0.52 * 0.8 + 0.54) / 2.4);
    close(result.confidence, (0.36 + 0.64 + 1.0) / 2.4);
    close(result.presence, (0.42 + 0.72 + 1.0) / 2.4);
    let diagnostic = result.ensemble.unwrap();
    assert_eq!(diagnostic.selected_indices, [0, 1, 2]);
    assert_eq!(diagnostic.method, EnsembleMethod::WeightedAgreement);
    assert_eq!(diagnostic.samples.len(), 3);
}

#[test]
fn strongest_agreeing_pair_excludes_a_high_confidence_different_target() {
    let result = combine(vec![
        sample(Some(rectangle(0.75, 0.95)), 0.99, 1.0),
        sample(Some(rectangle(0.1, 0.3)), 0.6, 0.8),
        sample(Some(rectangle(0.12, 0.32)), 0.8, 0.9),
    ]);
    assert_eq!(result.ensemble.as_ref().unwrap().selected_indices, [1, 2]);
    close(result.r#box.unwrap().left, (0.1 * 0.6 + 0.12 * 0.8) / 1.4);
    assert!(result.confidence <= 0.8);
}

#[test]
fn overlap_chain_cannot_bridge_three_different_targets() {
    let result = combine(vec![
        sample(Some(rectangle(0.0, 0.5)), 0.3, 0.9),
        sample(Some(rectangle(0.125, 0.625)), 0.8, 0.9),
        sample(Some(rectangle(0.25, 0.75)), 0.9, 0.9),
    ]);
    assert_eq!(result.ensemble.unwrap().selected_indices, [1, 2]);
    // Equal-strength, equal-overlap pairs choose the lowest indices.
    let tied = combine(vec![
        sample(Some(rectangle(0.0, 0.5)), 0.8, 0.9),
        sample(Some(rectangle(0.125, 0.625)), 0.8, 0.9),
        sample(Some(rectangle(0.25, 0.75)), 0.8, 0.9),
    ]);
    assert_eq!(tied.ensemble.unwrap().selected_indices, [0, 1]);
}

#[test]
fn threshold_is_inclusive_and_probabilities_are_not_multiplied() {
    let result = combine(vec![
        sample(Some(rectangle(0.0, 0.75)), 0.5, 0.8),
        sample(Some(rectangle(0.25, 1.0)), 0.5, 0.8),
        sample(None, 0.9, 0.1),
    ]);
    assert!(result.r#box.is_some());
    close(result.confidence, 0.5);
    close(result.presence, 0.8);
}

#[test]
fn disagreements_and_insufficient_usable_samples_abstain_with_diagnostics() {
    let result = combine(vec![
        sample(Some(rectangle(0.0, 0.2)), 0.8, 0.9),
        sample(Some(rectangle(0.4, 0.6)), 0.8, 0.9),
        sample(Some(rectangle(0.8, 1.0)), 0.8, 0.9),
    ]);
    assert_eq!(result.r#box, None);
    assert_eq!(
        result.ensemble.as_ref().unwrap().method,
        EnsembleMethod::NoAgreement
    );
    assert!(result.ensemble.unwrap().selected_indices.is_empty());
    close(result.confidence, 0.0);
    close(result.presence, 0.0);
    for confidence in [0.0, 0.8] {
        let insufficient = combine(vec![
            sample(Some(rectangle(0.1, 0.3)), confidence, 0.9),
            sample(None, 0.95, 0.1),
            sample(None, 0.1, 0.95),
        ]);
        assert_eq!(insufficient.r#box, None);
        assert_eq!(
            insufficient.ensemble.unwrap().method,
            EnsembleMethod::InsufficientValidSamples
        );
    }
}

#[test]
fn exact_unit_edges_remain_valid_after_weighting() {
    let a = NormalizedBox {
        top: 0.0,
        left: 0.0,
        bottom: 1.0,
        right: 1.0,
    };
    let result = combine(vec![
        sample(Some(a), 0.29, 1.0),
        sample(Some(a), 0.81, 1.0),
        sample(Some(a), 0.94, 1.0),
    ]);
    assert_eq!(result.r#box, Some(a));
    close(result.presence, 1.0);
}

#[test]
fn failed_group_preserves_rate_limit_and_largest_server_delay() {
    let error = finish(
        [
            Err(EngineError::local("Connection failed")),
            Err(EngineError::http(429, Some(2.0))),
            Err(EngineError::http(503, Some(7.0))),
        ],
        0.65,
        0.25,
    )
    .unwrap_err();
    assert_eq!(error.status, Some(429));
    assert_eq!(error.retry_after, Some(7.0));
}

#[test]
fn below_threshold_raw_boxes_are_recorded_but_cannot_vote() {
    let samples = vec![
        sample(Some(rectangle(0.1, 0.3)), 0.95, 0.1),
        sample(Some(rectangle(0.1, 0.3)), 0.1, 0.95),
        sample(Some(rectangle(0.1, 0.3)), 0.8, 0.9),
    ];
    let result = combine(samples.clone());
    assert!(result.r#box.is_none());
    let diagnostic = result.ensemble.unwrap();
    assert_eq!(diagnostic.samples, samples);
    assert!(diagnostic.selected_indices.is_empty());
    assert_eq!(diagnostic.method, EnsembleMethod::InsufficientValidSamples);
}
