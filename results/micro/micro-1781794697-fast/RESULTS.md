# autobench results

```
date: 2026-06-18T14:58:19Z
host: micro-t28x7
kernel: Linux 6.12.68+ x86_64
cpu: AMD EPYC 7B13
cores: 7
governor: n/a
turbo_no_turbo: n/a
ram: 31Gi
commit: n/a
rustc: n/a
server_cpus_default: 0-5
client_cpus_default: 6-7
dur: 8s  repeats: 2
```

Total cells: 56 rows. Throughput is median across repeats; **rps cv%** is the coefficient of variation (run-to-run noise).

## cpu_scaling

### append

| conn | engine | mode | ncpu | server_cpus | size | n | rps | p50_ms | p99_ms | max_ms | cpu_pct | rps_cv% |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 256 | raw | inline | 2 | 0-1 | 100 | 2 | 86,151 | 2.82 | 5.46 | 8.90 | 164 | 0.1 |
| 256 | raw | inline | 4 | 0-3 | 100 | 2 | 115,972 | 1.89 | 4.24 | 8.36 | 297 | 3.1 |
| 256 | raw | inline | 8 | 0-7 | 100 | 2 | 117,327 | 1.83 | 4.11 | 9.87 | 340 | 1.9 |
| 256 | raw | tail | 2 | 0-1 | 100 | 2 | 88,903 | 2.72 | 5.35 | 9.50 | 164 | 3.9 |
| 256 | raw | tail | 4 | 0-3 | 100 | 2 | 109,930 | 1.99 | 4.37 | 7.46 | 302 | 4.4 |
| 256 | raw | tail | 8 | 0-7 | 100 | 2 | 115,850 | 1.87 | 4.15 | 10.11 | 338 | 0.2 |

### read

| conn | engine | mode | ncpu | server_cpus | size | n | rps | p50_ms | p99_ms | max_ms | cpu_pct | rps_cv% |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 256 | raw | inline | 2 | 0-1 | 1024 | 2 | 213,829 | 0.40 | 6.16 | 11.87 | 197 | 2.5 |
| 256 | raw | inline | 4 | 0-3 | 1024 | 2 | 141,978 | 0.48 | 6.49 | 12.02 | 246 | 0.8 |
| 256 | raw | inline | 8 | 0-7 | 1024 | 2 | 147,644 | 0.52 | 5.95 | 12.21 | 278 | 0.8 |
| 256 | raw | tail | 2 | 0-1 | 1024 | 2 | 208,907 | 0.43 | 6.21 | 10.26 | 197 | 2.4 |
| 256 | raw | tail | 4 | 0-3 | 1024 | 2 | 139,552 | 0.49 | 6.53 | 11.47 | 252 | 1.1 |
| 256 | raw | tail | 8 | 0-7 | 1024 | 2 | 145,429 | 0.52 | 6.06 | 12.93 | 278 | 0.7 |

## engines

### append

| conn | engine | mode | server_cpus | size | n | rps | p50_ms | p99_ms | max_ms | cpu_pct | rps_cv% |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 64 | raw | inline | 0-5 | 100 | 2 | 60,652 | 0.92 | 2.74 | 5.63 | 215 | 0.1 |
| 64 | raw | tail | 0-5 | 100 | 2 | 59,350 | 0.95 | 2.79 | 4.78 | 220 | 0.6 |
| 256 | raw | inline | 0-5 | 100 | 2 | 120,950 | 1.77 | 4.09 | 8.09 | 355 | 1.0 |
| 256 | raw | tail | 0-5 | 100 | 2 | 119,213 | 1.79 | 4.16 | 8.67 | 350 | 0.4 |

### read_conn

| conn | engine | mode | server_cpus | size | n | rps | p50_ms | p99_ms | max_ms | cpu_pct | rps_cv% |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 64 | raw | inline | 0-5 | 1024 | 2 | 141,405 | 0.15 | 5.58 | 10.79 | 296 | 0.3 |
| 64 | raw | tail | 0-5 | 1024 | 2 | 141,677 | 0.14 | 5.51 | 12.29 | 292 | 3.8 |
| 256 | raw | inline | 0-5 | 1024 | 2 | 141,677 | 0.48 | 6.53 | 12.25 | 304 | 1.3 |
| 256 | raw | tail | 0-5 | 1024 | 2 | 146,460 | 0.47 | 6.47 | 14.76 | 298 | 2.2 |

### read_size

| conn | engine | mode | server_cpus | size | n | rps | p50_ms | p99_ms | max_ms | cpu_pct | rps_cv% |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 256 | raw | inline | 0-5 | 1024 | 2 | 144,291 | 0.47 | 6.52 | 12.14 | 300 | 0.6 |
| 256 | raw | inline | 0-5 | 16384 | 2 | 97,622 | 0.68 | 6.74 | 11.46 | 257 | 1.6 |
| 256 | raw | inline | 0-5 | 1048576 | 2 | 5,647 | 22.52 | 53.52 | 120 | 140 | 0.1 |
| 256 | raw | tail | 0-5 | 1024 | 2 | 145,425 | 0.47 | 6.42 | 11.34 | 301 | 2.0 |
| 256 | raw | tail | 0-5 | 16384 | 2 | 97,491 | 0.69 | 6.75 | 11.99 | 256 | 0.6 |
| 256 | raw | tail | 0-5 | 1048576 | 2 | 5,684 | 22.84 | 52.65 | 150 | 170 | 1.8 |

## splice

### append_bin

| conn | engine | readback | size | splice | n | rps | mbps | p50_ms | p99_ms | max_ms | cpu_pct | rps_cv% |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 64 | raw | ok | 1048576 | off | 2 | 391 | 391 | 163 | 293 | 310 | 70.50 | 1.0 |
| 64 | raw | ok | 1048576 | on | 2 | 393 | 393 | 163 | 283 | 288 | 44.50 | 0.1 |

