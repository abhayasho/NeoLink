//! Small statistics helpers used by the benchmark reports.

/// Linear-interpolated percentile (`q` in 0...1) of unsorted values; 0 for an empty slice.
pub fn percentile(values: &[f64], q: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted: Vec<f64> = values.iter().copied().filter(|v| v.is_finite()).collect();
    if sorted.is_empty() {
        return 0.0;
    }
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let rank = q.clamp(0.0, 1.0) * (sorted.len() - 1) as f64;
    let low = rank.floor() as usize;
    let high = rank.ceil() as usize;
    sorted[low] + (sorted[high] - sorted[low]) * (rank - low as f64)
}

pub fn mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        0.0
    } else {
        values.iter().sum::<f64>() / values.len() as f64
    }
}

pub fn max(values: &[f64]) -> f64 {
    values.iter().copied().fold(0.0, f64::max)
}

/// Rounds to `digits` decimal places, for compact JSON.
pub fn round_to(value: f64, digits: u32) -> f64 {
    let scale = 10f64.powi(digits as i32);
    (value * scale).round() / scale
}

/// Summary of a set of latencies in milliseconds.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Summary {
    pub count: usize,
    pub p50: f64,
    pub p95: f64,
    pub max: f64,
    pub mean: f64,
}

impl Summary {
    pub fn of(values: &[f64]) -> Summary {
        Summary {
            count: values.len(),
            p50: round_to(percentile(values, 0.5), 2),
            p95: round_to(percentile(values, 0.95), 2),
            max: round_to(max(values), 2),
            mean: round_to(mean(values), 2),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_interpolate() {
        let values = [4.0, 1.0, 3.0, 2.0];
        assert_eq!(percentile(&values, 0.0), 1.0);
        assert_eq!(percentile(&values, 1.0), 4.0);
        assert!((percentile(&values, 0.5) - 2.5).abs() < 1e-12);
        assert_eq!(percentile(&[], 0.5), 0.0);
    }

    #[test]
    fn summary_rounds() {
        let summary = Summary::of(&[10.0, 20.0, 30.0]);
        assert_eq!(summary.count, 3);
        assert_eq!(summary.p50, 20.0);
        assert_eq!(summary.max, 30.0);
        assert_eq!(summary.mean, 20.0);
    }
}
