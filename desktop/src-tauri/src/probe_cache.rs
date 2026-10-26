//! A small single-flight cache for bounded, read-only service probes.
//! Failure is a cacheable observation, never an empty successful result.
use std::sync::Mutex;
use std::time::{Duration, Instant};

struct Entry<T> {
    key: String,
    completed: Instant,
    result: Result<T, String>,
}

pub(crate) struct ProbeCache<T> {
    entry: Mutex<Option<Entry<T>>>,
}

impl<T: Clone> ProbeCache<T> {
    pub(crate) const fn new() -> Self {
        Self { entry: Mutex::new(None) }
    }

    // Call only from a blocking worker; the probe must have its own deadline.
    // Keeping this one lock across the probe coalesces concurrent callers too.
    // The cache holds one endpoint, so changing settings cannot reuse another
    // machine's answer, and a succession of endpoints cannot grow memory.
    pub(crate) fn get(
        &self,
        key: &str,
        ttl: Duration,
        probe: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, String> {
        let mut entry = self.entry.lock().map_err(|_| "Tjenestecachen er utilgjengelig.".to_string())?;
        if let Some(cached) = entry.as_ref() {
            if cached.key == key && cached.completed.elapsed() < ttl {
                return cached.result.clone();
            }
        }
        let result = probe();
        *entry = Some(Entry { key: key.to_string(), completed: Instant::now(), result: result.clone() });
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{atomic::{AtomicUsize, Ordering}, Arc, Barrier};

    #[test]
    fn offline_is_cached_as_failure_not_as_an_empty_model_list() {
        let cache = ProbeCache::<Vec<String>>::new();
        let ttl = Duration::from_secs(60);
        assert_eq!(cache.get("spark", ttl, || Err("offline".into())), Err("offline".into()));
        for _ in 0..50 {
            assert_eq!(cache.get("spark", ttl, || panic!("must not retry")), Err("offline".into()));
        }
    }

    #[test]
    fn expiry_allows_recovery_and_an_endpoint_change_is_immediate() {
        let cache = ProbeCache::new();
        let ttl = Duration::from_secs(60);
        assert!(cache.get("old", ttl, || Err::<Vec<String>, _>("offline".into())).is_err());
        assert_eq!(cache.get("new", ttl, || Ok(vec!["local".into()])), Ok(vec!["local".into()]));
        assert_eq!(cache.get("new", Duration::ZERO, || Ok(vec!["recovered".into()])), Ok(vec!["recovered".into()]));
        assert_eq!(cache.get("new", ttl, || panic!("must reuse")), Ok(vec!["recovered".into()]));
    }

    #[test]
    fn parallel_offline_requests_make_one_bounded_probe() {
        let cache = Arc::new(ProbeCache::<Vec<String>>::new());
        let calls = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(8));
        let threads: Vec<_> = (0..8).map(|_| {
            let (cache, calls, barrier) = (cache.clone(), calls.clone(), barrier.clone());
            std::thread::spawn(move || {
                barrier.wait();
                cache.get("spark", Duration::from_secs(60), || {
                    calls.fetch_add(1, Ordering::SeqCst);
                    std::thread::sleep(Duration::from_millis(20));
                    Err("offline".into())
                })
            })
        }).collect();
        for thread in threads { assert_eq!(thread.join().unwrap(), Err("offline".into())); }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
}
