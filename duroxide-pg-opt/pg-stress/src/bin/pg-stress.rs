use clap::Parser;
use duroxide_pg_stress::{
    run_all_stress_tests, run_large_payload_suite, run_test_suite, StressTestType,
};
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "pg-stress")]
#[command(about = "PostgreSQL provider stress tests for Duroxide", long_about = None)]
struct Args {
    /// Duration of each stress test in seconds
    #[arg(short, long, default_value = "5")]
    duration: u64,

    /// PostgreSQL connection URL (or set DATABASE_URL env var)
    #[arg(short = 'u', long)]
    database_url: Option<String>,

    /// Type of stress test to run: parallel, large-payload, or all
    #[arg(short = 't', long, default_value = "parallel")]
    test_type: String,

    /// Track results to file for comparison
    #[arg(long)]
    track: bool,

    /// Track results with cloud environment tag
    #[arg(long)]
    track_cloud: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize logging
    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_target(false)
        .init();

    // Load .env if present
    dotenvy::dotenv().ok();

    let args = Args::parse();

    // Get database URL from args or environment
    let database_url = args
        .database_url
        .or_else(|| std::env::var("DATABASE_URL").ok())
        .expect("DATABASE_URL must be provided via --database-url or DATABASE_URL env var");

    // Parse test type
    let test_type: StressTestType = args.test_type.parse()?;

    // Run appropriate stress test(s)
    match test_type {
        StressTestType::Parallel => {
            run_test_suite(database_url.clone(), args.duration).await?;
        }
        StressTestType::LargePayload => {
            run_large_payload_suite(database_url.clone(), args.duration).await?;
        }
        StressTestType::All => {
            run_all_stress_tests(database_url.clone(), args.duration).await?;
        }
    }

    // Show results filename for reference
    let results_file = duroxide_pg_stress::get_results_filename(&database_url);
    eprintln!("\nResults can be tracked in: {}", results_file);

    if args.track || args.track_cloud {
        eprintln!("Note: Automatic result tracking not yet implemented");
        eprintln!(
            "Manually append results to {} for historical tracking",
            results_file
        );
    }

    Ok(())
}
