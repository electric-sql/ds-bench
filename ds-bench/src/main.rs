mod backend;
mod bootstrap;
mod catch_up;
mod common;
mod dist;
mod fanout;
mod mixed;
mod multi_stream;
mod sse_util;
mod sustained;

use anyhow::Result;
use clap::Parser;
use clap::Subcommand;

#[derive(Parser, Debug)]
#[command(
    name = "ursula-bench",
    version,
    about = "Ursula real-world workload benchmark client"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Multi-stream concurrent write - proves multi-Raft sharding scales with stream count.
    MultiStream(multi_stream::MultiStreamArgs),
    /// SSE fan-out - single stream, many subscribers, measure per-event end-to-end latency.
    FanOut(fanout::FanOutArgs),
    /// Bootstrap stampede - N clients hit /bootstrap simultaneously after a snapshot.
    Bootstrap(bootstrap::BootstrapArgs),
    /// Catch-up stampede - N clients replay a pre-populated stream from offset -1 simultaneously.
    CatchUp(catch_up::CatchUpArgs),
    /// Mixed workload - concurrent writers + catch-up readers + live SSE subscribers.
    Mixed(mixed::MixedArgs),
    /// Sustained steady-rate load over N streams — measures latency/throughput stability over time.
    Sustained(sustained::SustainedArgs),
    /// Merge per-pod HDR histograms into exact fleet-wide percentiles.
    HdrMerge(dist::HdrMergeArgs),
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_target(true)
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();
    let json = match cli.cmd {
        Cmd::MultiStream(args) => serde_json::to_string_pretty(&multi_stream::run(args).await?)?,
        Cmd::FanOut(args) => serde_json::to_string_pretty(&fanout::run(args).await?)?,
        Cmd::Bootstrap(args) => serde_json::to_string_pretty(&bootstrap::run(args).await?)?,
        Cmd::CatchUp(a) => serde_json::to_string_pretty(&catch_up::run(a).await?)?,
        Cmd::Mixed(a) => serde_json::to_string_pretty(&mixed::run(a).await?)?,
        Cmd::Sustained(a) => serde_json::to_string_pretty(&sustained::run(a).await?)?,
        Cmd::HdrMerge(a) => dist::run_merge(a)?,
    };
    println!("{json}");
    Ok(())
}
