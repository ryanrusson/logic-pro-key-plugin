//! Wait-free single-producer / single-consumer ring buffer of `f32` samples.
//!
//! The producer is Logic's realtime render thread: it must never lock,
//! allocate, or block. When the buffer is full, samples are dropped (and
//! counted) rather than waiting on the consumer.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

pub struct SpscRing {
    buf: Box<[UnsafeCell<f32>]>,
    mask: usize,
    head: AtomicUsize, // next write index (producer-owned)
    tail: AtomicUsize, // next read index (consumer-owned)
    dropped: AtomicU64,
}

// Safety: producer only writes slots in [head, tail + cap), consumer only reads
// slots in [tail, head); acquire/release on the indices orders those accesses.
unsafe impl Sync for SpscRing {}
unsafe impl Send for SpscRing {}

impl SpscRing {
    pub fn with_capacity_pow2(capacity: usize) -> Self {
        let cap = capacity.next_power_of_two();
        let buf = (0..cap).map(|_| UnsafeCell::new(0.0)).collect::<Vec<_>>().into_boxed_slice();
        Self { buf, mask: cap - 1, head: AtomicUsize::new(0), tail: AtomicUsize::new(0), dropped: AtomicU64::new(0) }
    }

    pub fn capacity(&self) -> usize {
        self.mask + 1
    }

    /// Producer side. Writes `f(i)` for i in 0..n; returns the number written.
    #[inline]
    pub fn push_with(&self, n: usize, mut f: impl FnMut(usize) -> f32) -> usize {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);
        let free = self.capacity() - head.wrapping_sub(tail);
        let count = n.min(free);
        for i in 0..count {
            unsafe { *self.buf[(head.wrapping_add(i)) & self.mask].get() = f(i) };
        }
        self.head.store(head.wrapping_add(count), Ordering::Release);
        if count < n {
            self.dropped.fetch_add((n - count) as u64, Ordering::Relaxed);
        }
        count
    }

    /// Consumer side. Moves everything currently available into `out`.
    pub fn drain_into(&self, out: &mut Vec<f32>) -> usize {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);
        let avail = head.wrapping_sub(tail);
        out.reserve(avail);
        for i in 0..avail {
            out.push(unsafe { *self.buf[(tail.wrapping_add(i)) & self.mask].get() });
        }
        self.tail.store(head, Ordering::Release);
        avail
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn overflow_drops_instead_of_blocking() {
        let r = SpscRing::with_capacity_pow2(8);
        assert_eq!(r.push_with(10, |i| i as f32), 8);
        assert_eq!(r.dropped(), 2);
        let mut v = Vec::new();
        r.drain_into(&mut v);
        assert_eq!(v, (0..8).map(|i| i as f32).collect::<Vec<_>>());
    }

    #[test]
    fn concurrent_transfer_preserves_order() {
        let r = Arc::new(SpscRing::with_capacity_pow2(1024));
        let p = r.clone();
        let total = 200_000usize;
        let producer = std::thread::spawn(move || {
            let mut sent = 0;
            while sent < total {
                sent += p.push_with((total - sent).min(97), |i| (sent + i) as f32);
            }
        });
        let mut got = Vec::new();
        while got.len() < total {
            r.drain_into(&mut got);
        }
        producer.join().unwrap();
        // Drops are allowed only when full; the producer retries, so none here.
        assert!(got.iter().enumerate().all(|(i, &x)| x == i as f32));
    }
}
