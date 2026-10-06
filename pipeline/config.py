"""Shared settings for the pipeline. Override any of them with environment variables."""

import os

from google.cloud import bigquery

# Shared course dataset the pipeline reads from.
SOURCE = os.environ.get("ED_SOURCE_DATASET", "msbai-capstone-energydrinks.energy_drinks")

# Dataset in your own project that the pipeline writes to.
TARGET_PROJECT = os.environ.get("ED_TARGET_PROJECT", "msbai-capstone-energy-drinks")
TARGET = f"{TARGET_PROJECT}.{os.environ.get('ED_TARGET_DATASET', 'energy_drinks_analytics')}"
TARGET_LOCATION = "US"  # must match the source dataset's location


def get_client(project: str) -> bigquery.Client:
    token = os.environ.get("GCP_ACCESS_TOKEN")
    if token:
        from google.oauth2.credentials import Credentials

        return bigquery.Client(project=project, credentials=Credentials(token))
    return bigquery.Client(project=project)
