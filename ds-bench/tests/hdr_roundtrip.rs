use hdrhistogram::Histogram;

#[test]
fn emit_then_merge_roundtrips_exactly() {
    let dir = std::env::temp_dir().join("ds-bench-hdr-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    unsafe { std::env::set_var("DS_BENCH_HDR_OUT", &dir); }

    // two "pods" each record a known set of values
    let mut a = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    let mut b = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for v in [10u64, 20, 30] { a.record(v).unwrap(); }
    for v in [40u64, 50, 60] { b.record(v).unwrap(); }
    ds_bench::dist::emit_hdr(&a, "pod-a");
    ds_bench::dist::emit_hdr(&b, "pod-b");

    // merge from the directory == a single histogram over all six values
    let merged = ds_bench::dist::merge_dir(&dir).unwrap();
    let mut expected = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for v in [10u64, 20, 30, 40, 50, 60] { expected.record(v).unwrap(); }
    assert_eq!(merged.len(), expected.len());
    assert_eq!(merged.value_at_quantile(0.5), expected.value_at_quantile(0.5));
    assert_eq!(merged.max(), expected.max());
}

#[test]
fn hdr_merge_summary_matches_merged_histogram() {
    let dir = std::env::temp_dir().join("ds-bench-hdr-merge-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut a = Histogram::<u64>::new_with_bounds(1, 60_000_000, 3).unwrap();
    for v in 1u64..=1000 { a.record(v * 1000).unwrap(); } // values in µs
    {
        use hdrhistogram::serialization::{Serializer, V2Serializer};
        let mut buf = Vec::new();
        V2Serializer::new().serialize(&a, &mut buf).unwrap();
        std::fs::write(dir.join("only.hdr"), &buf).unwrap();
    }
    let summary = ds_bench::dist::merge_summary(&dir, None).unwrap();
    assert_eq!(summary.merged_count, 1000);
    // p50 of 1..=1000 (×1000 µs) ≈ 500 ms, within HDR precision
    assert!((summary.p50_ms - 500.0).abs() < 5.0, "p50_ms={}", summary.p50_ms);
}
