use crate::models::*;

pub const IOU_THRESHOLD: f64 = 0.5;

pub fn intersection_over_union(a: NormalizedBox, b: NormalizedBox) -> f64 {
    if !a.is_valid() || !b.is_valid() {
        return 0.0;
    }
    let intersection = (a.right.min(b.right) - a.left.max(b.left)).max(0.0)
        * (a.bottom.min(b.bottom) - a.top.max(b.top)).max(0.0);
    let union = (a.right - a.left) * (a.bottom - a.top) + (b.right - b.left) * (b.bottom - b.top)
        - intersection;
    if union > 0.0 {
        intersection / union
    } else {
        0.0
    }
}

/// Retain raw samples for diagnostics; only supported samples may vote.
/// Never average different targets into empty space.
pub fn combine(
    samples: Vec<GuidanceSample>,
    minimum_presence: f64,
    minimum_confidence: f64,
) -> GuidanceResult {
    let valid: Vec<_> = samples
        .iter()
        .enumerate()
        .filter_map(|(index, sample)| {
            (sample.r#box.is_some_and(|b| b.is_valid())
                && valid_probability(sample.confidence)
                && sample.confidence > 0.0
                && sample.confidence >= minimum_confidence
                && valid_probability(sample.presence)
                && sample.presence >= minimum_presence)
                .then_some(index)
        })
        .collect();
    let agrees = |a: usize, b: usize| {
        intersection_over_union(samples[a].r#box.unwrap(), samples[b].r#box.unwrap())
            >= IOU_THRESHOLD
    };
    let mut selected = Vec::new();
    if valid.len() == 3
        && agrees(valid[0], valid[1])
        && agrees(valid[0], valid[2])
        && agrees(valid[1], valid[2])
    {
        selected = valid.clone();
    } else {
        let mut strongest: Option<(f64, f64)> = None;
        for first in 0..valid.len() {
            for second in first + 1..valid.len() {
                let (a, b) = (valid[first], valid[second]);
                if !agrees(a, b) {
                    continue;
                }
                let score = (
                    samples[a].confidence + samples[b].confidence,
                    intersection_over_union(samples[a].r#box.unwrap(), samples[b].r#box.unwrap()),
                );
                // Iteration order supplies the final deterministic index tie.
                if strongest.is_none_or(|best| score > best) {
                    strongest = Some(score);
                    selected = vec![a, b];
                }
            }
        }
    }
    let mut result = GuidanceResult {
        r#box: None,
        confidence: 0.0,
        presence: 0.0,
        ensemble: None,
    };
    let mut method = if valid.len() < 2 {
        EnsembleMethod::InsufficientValidSamples
    } else {
        EnsembleMethod::NoAgreement
    };
    if !selected.is_empty() {
        let total: f64 = selected.iter().map(|&i| samples[i].confidence).sum();
        let mut averaged = NormalizedBox {
            top: 0.0,
            bottom: 0.0,
            left: 0.0,
            right: 0.0,
        };
        for &index in &selected {
            let sample = samples[index];
            let box_value = sample.r#box.unwrap();
            let weight = sample.confidence;
            averaged.top += weight * box_value.top;
            averaged.bottom += weight * box_value.bottom;
            averaged.left += weight * box_value.left;
            averaged.right += weight * box_value.right;
            result.confidence += weight * sample.confidence;
            result.presence += weight * sample.presence;
        }
        averaged.top /= total;
        averaged.bottom /= total;
        averaged.left /= total;
        averaged.right /= total;
        result.confidence /= total;
        result.presence /= total;
        if averaged.is_valid() {
            result.r#box = Some(averaged);
            method = EnsembleMethod::WeightedAgreement;
        } else {
            // Extremely small floating-point boxes can collapse on averaging.
            // Do not repair their geometry or report a successful agreement.
            selected.clear();
            result.confidence = 0.0;
            result.presence = 0.0;
        }
    }
    result.ensemble = Some(EnsembleDiagnostics {
        samples,
        selected_indices: selected,
        method,
        iou_threshold: IOU_THRESHOLD,
    });
    result
}

/// All sample futures finish before this is called. A partially successful
/// group must not conceal a rate limit or shorten any server retry deadline.
pub fn finish(
    outcomes: [Result<GuidanceSample, EngineError>; 3],
    minimum_presence: f64,
    minimum_confidence: f64,
) -> Result<GuidanceResult, EngineError> {
    let mut samples = Vec::new();
    let mut errors = Vec::new();
    for outcome in outcomes {
        match outcome {
            Ok(sample) => samples.push(sample),
            Err(error) => errors.push(error),
        }
    }
    if errors.is_empty() {
        return Ok(combine(samples, minimum_presence, minimum_confidence));
    }
    let retry_after = errors
        .iter()
        .filter_map(|error| error.retry_after)
        .filter(|delay| delay.is_finite() && *delay >= 0.0)
        .max_by(f64::total_cmp);
    let selected = errors
        .iter()
        .position(|error| error.status == Some(429))
        .unwrap_or_else(|| {
            errors
                .iter()
                .position(|error| error.retry_after == retry_after)
                .unwrap_or(0)
        });
    let mut error = errors.remove(selected);
    error.retry_after = retry_after;
    error.completed_calls = Some(samples.len());
    Err(error)
}

#[cfg(test)]
mod tests;
