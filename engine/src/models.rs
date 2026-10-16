use serde::{Deserialize, Serialize};

pub const MAX_REQUEST_BYTES: usize = 24 * 1024 * 1024;
pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;

// Intentionally no Debug implementation on requests: they contain a credential
// and private context that must never appear in diagnostics.
#[derive(Deserialize)]
pub struct Request {
    pub id: String,
    pub api_key: String,
    pub model: String,
    pub minimum_presence: f64,
    pub minimum_confidence: f64,
    #[serde(flatten)]
    pub operation: Operation,
}

#[derive(Deserialize)]
#[serde(tag = "op", content = "input", rename_all = "snake_case")]
pub enum Operation {
    Guidance(GuidanceInput),
    Goal(GoalInput),
}

#[derive(Deserialize)]
pub struct GuidanceInput {
    pub transcript: String,
    pub goal: Option<String>,
    pub notes: String,
    pub browser_context: Option<String>,
    pub accessibility_context: Option<String>,
    pub image_jpeg_base64: String,
    #[serde(default = "default_sample_count")]
    pub sample_count: u8,
}

fn default_sample_count() -> u8 {
    1
}

#[derive(Deserialize)]
pub struct GoalInput {
    pub transcript: String,
    pub previous_goal: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub struct NormalizedBox {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
}

impl NormalizedBox {
    pub fn is_valid(&self) -> bool {
        [self.top, self.bottom, self.left, self.right]
            .into_iter()
            .all(valid_probability)
            && self.top < self.bottom
            && self.left < self.right
    }
}

pub fn valid_probability(value: f64) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}

#[derive(Debug, Serialize, PartialEq)]
pub struct GuidanceResult {
    pub r#box: Option<NormalizedBox>,
    pub confidence: f64,
    pub presence: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ensemble: Option<EnsembleDiagnostics>,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq)]
pub struct GuidanceSample {
    pub r#box: Option<NormalizedBox>,
    pub confidence: f64,
    pub presence: f64,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct EnsembleDiagnostics {
    pub samples: Vec<GuidanceSample>,
    pub selected_indices: Vec<usize>,
    pub method: EnsembleMethod,
    pub iou_threshold: f64,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum EnsembleMethod {
    WeightedAgreement,
    NoAgreement,
    InsufficientValidSamples,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(untagged)]
pub enum ResultValue {
    Guidance(GuidanceResult),
    Goal { goal: Option<String> },
}

#[derive(Debug, Serialize, PartialEq)]
pub struct EngineError {
    pub message: String,
    pub retry_after: Option<f64>,
    pub status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_calls: Option<usize>,
}

impl EngineError {
    pub fn local(message: &str) -> Self {
        Self {
            message: message.to_owned(),
            retry_after: None,
            status: None,
            completed_calls: None,
        }
    }

    pub fn http(status: u16, retry_after: Option<f64>) -> Self {
        let message = match status {
            401 | 403 => "TypeSafe rejected the API key or its access.",
            429 => "TypeSafe rate limit reached. Retry after a short backoff.",
            529 => "TypeSafe is temporarily overloaded. Retry shortly.",
            _ => "TypeSafe request failed.",
        };
        Self {
            message: message.to_owned(),
            retry_after,
            status: Some(status),
            completed_calls: None,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<ResultValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<EngineError>,
}

impl Response {
    pub fn new(id: String, result: Result<ResultValue, EngineError>) -> Self {
        match result {
            Ok(value) => Self {
                id,
                ok: true,
                result: Some(value),
                error: None,
            },
            Err(error) => Self {
                id,
                ok: false,
                result: None,
                error: Some(error),
            },
        }
    }
}
