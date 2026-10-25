//! Key estimation by correlating a chroma vector with tonal key profiles.

pub const NOTE_NAMES: [&str; 12] = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"];

// Krumhansl & Kessler (1982) probe-tone ratings.
const KK_MAJOR: [f32; 12] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KK_MINOR: [f32; 12] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
// Temperley (2007), Kostka-Payne corpus.
const TP_MAJOR: [f32; 12] = [0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400];
const TP_MINOR: [f32; 12] = [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Key {
    /// Pitch class of the tonic, 0 = C.
    pub tonic: u8,
    pub minor: bool,
}

impl Key {
    pub fn name(&self) -> String {
        format!("{} {}", NOTE_NAMES[self.tonic as usize], if self.minor { "minor" } else { "major" })
    }

    /// Index 0..24: majors 0..12, minors 12..24.
    pub fn index(&self) -> usize {
        self.tonic as usize + if self.minor { 12 } else { 0 }
    }

    pub fn relative(&self) -> Key {
        if self.minor {
            Key { tonic: (self.tonic + 3) % 12, minor: false }
        } else {
            Key { tonic: (self.tonic + 9) % 12, minor: true }
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Candidate {
    pub key: Key,
    pub score: f32,
}

#[derive(Clone, Debug)]
pub struct Estimate {
    /// All 24 keys, best first.
    pub ranked: Vec<Candidate>,
    /// 0..1: how clearly the winner beats the runner-up.
    pub confidence: f32,
}

fn pearson(x: &[f32; 12], profile: &[f32; 12], shift: usize) -> f32 {
    let mx = x.iter().sum::<f32>() / 12.0;
    let mp = profile.iter().sum::<f32>() / 12.0;
    let (mut num, mut dx, mut dp) = (0.0, 0.0, 0.0);
    for i in 0..12 {
        let a = x[(i + shift) % 12] - mx;
        let b = profile[i] - mp;
        num += a * b;
        dx += a * a;
        dp += b * b;
    }
    if dx <= 0.0 || dp <= 0.0 { 0.0 } else { num / (dx * dp).sqrt() }
}

/// Score all 24 keys. The score is the mean Pearson correlation against the
/// Krumhansl-Kessler and Temperley profiles; averaging two profiles that
/// were derived very differently is more robust than either alone.
///
/// `tonality` (0..1, see `PitchHistogram::tonality`) scales confidence so
/// that noise, which still yields *some* best-correlating key, reads as
/// unconfident.
pub fn estimate(chroma: &[f32; 12], tonality: f32) -> Option<Estimate> {
    if chroma.iter().all(|&c| c <= 0.0) {
        return None;
    }
    let mut ranked: Vec<Candidate> = (0..24)
        .map(|k| {
            let minor = k >= 12;
            let tonic = (k % 12) as usize;
            let (a, b) = if minor { (&KK_MINOR, &TP_MINOR) } else { (&KK_MAJOR, &TP_MAJOR) };
            let score = 0.5 * (pearson(chroma, a, tonic) + pearson(chroma, b, tonic));
            Candidate { key: Key { tonic: tonic as u8, minor }, score }
        })
        .collect();
    ranked.sort_by(|a, b| b.score.total_cmp(&a.score));

    let best = ranked[0].score;
    let second = ranked[1].score;
    // Margin-based confidence, scaled so a 0.15 lead (a clear result in
    // practice) saturates, then gated by how tonal the chroma is at all.
    let margin = ((best - second) / 0.15).clamp(0.0, 1.0);
    let fit = ((best - 0.3) / 0.5).clamp(0.0, 1.0);
    let pitched = ((tonality - 0.10) / 0.15).clamp(0.0, 1.0);
    Some(Estimate { confidence: margin * fit * pitched, ranked })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profiles_identify_themselves_in_every_key() {
        for t in 0..12 {
            let mut c = [0.0f32; 12];
            for i in 0..12 {
                c[(i + t) % 12] = KK_MAJOR[i];
            }
            assert_eq!(estimate(&c, 1.0).unwrap().ranked[0].key, Key { tonic: t as u8, minor: false });
            for i in 0..12 {
                c[(i + t) % 12] = KK_MINOR[i];
            }
            assert_eq!(estimate(&c, 1.0).unwrap().ranked[0].key, Key { tonic: t as u8, minor: true });
        }
    }

    #[test]
    fn relative_keys() {
        let c = Key { tonic: 0, minor: false };
        assert_eq!(c.relative().name(), "A minor");
        assert_eq!(c.relative().relative(), c);
    }
}
