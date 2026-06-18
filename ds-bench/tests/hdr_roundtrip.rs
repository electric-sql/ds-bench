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
