"""Build the energy-drink analytics tables in BigQuery.

Reads from the shared source dataset and writes one table per file in
pipeline/sql/ (run in filename order) to a dataset in your own project.

Usage:
    python -m pipeline.run_pipeline              # build every table
    python -m pipeline.run_pipeline --dry-run    # validate SQL and estimate bytes scanned
    python -m pipeline.run_pipeline --only 07    # rebuild steps whose filename starts with 07

Auth uses Application Default Credentials (`gcloud auth application-default login`),
or a short-lived OAuth token in the GCP_ACCESS_TOKEN environment variable.
"""

import argparse
import sys
from pathlib import Path

from google.api_core.exceptions import NotFound
from google.cloud import bigquery

from pipeline.config import SOURCE, TARGET, TARGET_LOCATION, TARGET_PROJECT, get_client

SQL_DIR = Path(__file__).parent / "sql"


def render(path: Path) -> str:
    return path.read_text().replace("{src}", SOURCE).replace("{dst}", TARGET)


def ensure_dataset(client: bigquery.Client) -> None:
    try:
        client.get_dataset(TARGET)
    except NotFound:
        dataset = bigquery.Dataset(TARGET)
        dataset.location = TARGET_LOCATION
        dataset.description = f"Energy-drink analytics tables built from {SOURCE}."
        client.create_dataset(dataset)
        print(f"Created dataset {TARGET}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="validate SQL and report bytes, build nothing")
    parser.add_argument("--only", nargs="*", default=[], help="filename prefixes of steps to run")
    args = parser.parse_args()

    client = get_client(TARGET_PROJECT)
    steps = sorted(SQL_DIR.glob("*.sql"))
    if args.only:
        steps = [s for s in steps if any(s.name.startswith(p) for p in args.only)]

    if not args.dry_run:
        ensure_dataset(client)

    total_bytes = 0
    for step in steps:
        config = bigquery.QueryJobConfig(dry_run=args.dry_run, use_query_cache=False)
        try:
            job = client.query(render(step), job_config=config, location=TARGET_LOCATION)
            if not args.dry_run:
                job.result()
        except Exception as exc:  # report which step failed, then stop
            # A dry run of a step that reads a not-yet-built table fails with NotFound; that's expected.
            if args.dry_run and isinstance(exc, NotFound) and TARGET in str(exc):
                print(f"{step.name:32s} skipped (depends on a table not yet built)")
                continue
            print(f"{step.name:32s} FAILED\n{exc}", file=sys.stderr)
            return 1
        scanned = job.total_bytes_processed or 0
        total_bytes += scanned
        print(f"{step.name:32s} {'ok (dry run)' if args.dry_run else 'built'}  {scanned / 1e9:8.2f} GB")

    print(f"{'total':32s} {total_bytes / 1e9:22.2f} GB scanned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
