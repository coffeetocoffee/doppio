"""
Doppio Export Module

Exports analysis results and dbt models to Parquet and CSV formats.
Ensures deterministic row ordering for reproducible, diffable exports.
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional
import sqlite3

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq


@dataclass
class ExportManifest:
    """Manifest describing an export batch."""
    export_id: str
    timestamp: str
    experiment_key: str
    workspace_id: str
    environment_id: str
    tables: list[dict]
    schema_version: str = "1.0"
    
    def to_dict(self) -> dict:
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: dict) -> ExportManifest:
        return cls(**data)


class DeterministicExporter:
    """
    Exports database tables to Parquet/CSV with deterministic ordering.
    
    Key guarantees:
    - Rows sorted by primary key (or all columns if no PK)
    - Column order fixed by schema
    - Nulls sort first
    - Timestamps in ISO 8601 UTC
    """
    
    def __init__(self, db_path: str, output_dir: str):
        self.db_path = db_path
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def _get_table_columns(self, conn: sqlite3.Connection, table: str) -> list[str]:
        """Get column names in declared order."""
        cursor = conn.cursor()
        cursor.execute(f"PRAGMA table_info({table})")
        return [row[1] for row in cursor.fetchall()]
    
    def _get_primary_key(self, conn: sqlite3.Connection, table: str) -> list[str]:
        """Get primary key columns."""
        cursor = conn.cursor()
        cursor.execute(f"PRAGMA table_info({table})")
        pk_cols = [row[1] for row in cursor.fetchall() if row[5] == 1]
        return pk_cols if pk_cols else []
    
    def _deterministic_order(self, df: pd.DataFrame, pk_cols: list[str]) -> pd.DataFrame:
        """Sort rows deterministically."""
        if pk_cols:
            sort_cols = [c for c in pk_cols if c in df.columns]
        else:
            sort_cols = list(df.columns)
        
        # Ensure all sort columns exist
        sort_cols = [c for c in sort_cols if c in df.columns]
        if not sort_cols:
            return df
        
        # Sort with nulls first
        return df.sort_values(by=sort_cols, na_position='first').reset_index(drop=True)
    
    def _normalize_timestamps(self, df: pd.DataFrame) -> pd.DataFrame:
        """Convert timestamp columns to ISO 8601 UTC strings."""
        for col in df.columns:
            if df[col].dtype == 'datetime64[ns]' or 'timestamp' in col.lower() or '_at' in col.lower():
                try:
                    # Convert to datetime if not already
                    if df[col].dtype != 'datetime64[ns]':
                        df[col] = pd.to_datetime(df[col], unit='ms', errors='ignore')
                    if df[col].dtype == 'datetime64[ns]':
                        # Format as ISO 8601 UTC
                        df[col] = df[col].dt.strftime('%Y-%m-%dT%H:%M:%S.%fZ').replace('NaT', '')
                except Exception:
                    pass  # Leave as-is if conversion fails
        return df
    
    def export_table(
        self,
        table: str,
        formats: list[str] = None,
        where: str = None,
        params: tuple = None
    ) -> dict:
        """
        Export a single table to Parquet and/or CSV.
        
        Returns dict with file paths and row count.
        """
        if formats is None:
            formats = ['parquet', 'csv']
        
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        
        # Build query
        pk_cols = self._get_primary_key(conn, table)
        columns = self._get_table_columns(conn, table)
        
        query = f"SELECT {', '.join(columns)} FROM {table}"
        if where:
            query += f" WHERE {where}"
        
        # Add ORDER BY for deterministic results
        if pk_cols:
            order_cols = ', '.join(pk_cols)
        else:
            order_cols = ', '.join(columns)
        query += f" ORDER BY {order_cols}"
        
        # Read into pandas
        df = pd.read_sql_query(query, conn, params=params)
        conn.close()
        
        # Normalize
        df = self._normalize_timestamps(df)
        df = self._deterministic_order(df, pk_cols)
        
        # Ensure column order
        df = df[columns]
        
        results = {'table': table, 'rows': len(df), 'columns': columns, 'files': {}}
        
        for fmt in formats:
            if fmt == 'parquet':
                path = self.output_dir / f"{table}.parquet"
                # Write with explicit schema for reproducibility
                table_pa = pa.Table.from_pandas(df, preserve_index=False)
                pq.write_table(
                    table_pa,
                    path,
                    compression='snappy',
                    use_dictionary=False,  # Disable for reproducibility
                    write_statistics=False
                )
                results['files']['parquet'] = str(path)
            
            elif fmt == 'csv':
                path = self.output_dir / f"{table}.csv"
                df.to_csv(
                    path,
                    index=False,
                    quoting=csv.QUOTE_MINIMAL,
                    lineterminator='\n',
                    date_format='%Y-%m-%dT%H:%M:%S.%fZ'
                )
                results['files']['csv'] = str(path)
        
        return results
    
    def export_experiment(
        self,
        experiment_key: str,
        workspace_id: str = "default",
        environment_id: str = "default",
        formats: list[str] = None
    ) -> ExportManifest:
        """
        Export all tables related to an experiment.
        
        Exports: experiment_assignments, fct_exposures, and all metric tables
        filtered to the experiment.
        """
        if formats is None:
            formats = ['parquet', 'csv']
        
        exp_dir = self.output_dir / f"experiment_{experiment_key}"
        exp_dir.mkdir(parents=True, exist_ok=True)
        
        # Create sub-exporter for experiment-specific output
        exp_exporter = DeterministicExporter(self.db_path, str(exp_dir))
        
        tables_exported = []
        
        # Export experiment assignments
        result = exp_exporter.export_table(
            'experiment_assignments',
            formats=formats,
            where="experiment_key = ? AND workspace_id = ? AND environment_id = ?",
            params=(experiment_key, workspace_id, environment_id)
        )
        tables_exported.append(result)
        
        # Export fact exposures
        result = exp_exporter.export_table(
            'fct_exposures',
            formats=formats,
            where="experiment_key = ? AND workspace_id = ? AND environment_id = ?",
            params=(experiment_key, workspace_id, environment_id)
        )
        tables_exported.append(result)
        
        # Export metric tables
        metric_tables = ['conversion', 'ratio', 'distribution', 'retention', 'funnel']
        for metric in metric_tables:
            result = exp_exporter.export_table(
                metric,
                formats=formats,
                where="experiment_key = ? AND workspace_id = ? AND environment_id = ?",
                params=(experiment_key, workspace_id, environment_id)
            )
            tables_exported.append(result)
        
        # Export dim_flags if relevant
        result = exp_exporter.export_table(
            'dim_flags',
            formats=formats,
            where="flag_key = ? AND workspace_id = ? AND environment_id = ?",
            params=(experiment_key, workspace_id, environment_id)
        )
        tables_exported.append(result)
        
        # Create manifest
        import datetime
        manifest = ExportManifest(
            export_id=hashlib.sha256(
                f"{experiment_key}{workspace_id}{environment_id}{datetime.datetime.utcnow().isoformat()}".encode()
            ).hexdigest()[:16],
            timestamp=datetime.datetime.utcnow().isoformat() + 'Z',
            experiment_key=experiment_key,
            workspace_id=workspace_id,
            environment_id=environment_id,
            tables=tables_exported
        )
        
        # Write manifest
        manifest_path = exp_dir / 'manifest.json'
        with open(manifest_path, 'w') as f:
            json.dump(manifest.to_dict(), f, indent=2, sort_keys=True)
        
        return manifest


def verify_roundtrip(export_dir: str) -> dict:
    """
    Verify Parquet/CSV round-trip consistency.
    
    Checks:
    - Row counts match
    - Column names and order match
    - All values match (within floating point tolerance)
    """
    export_path = Path(export_dir)
    results = {'tables': [], 'all_passed': True}
    
    for parquet_file in export_path.glob('*.parquet'):
        table_name = parquet_file.stem
        csv_file = export_path / f"{table_name}.csv"
        
        if not csv_file.exists():
            results['tables'].append({
                'table': table_name,
                'passed': False,
                'error': 'CSV file not found'
            })
            results['all_passed'] = False
            continue
        
        # Read both
        df_parquet = pd.read_parquet(parquet_file)
        df_csv = pd.read_csv(csv_file)
        
        # Compare
        checks = {
            'rows_match': len(df_parquet) == len(df_csv),
            'columns_match': list(df_parquet.columns) == list(df_csv.columns),
        }
        
        if checks['rows_match'] and checks['columns_match']:
            # Compare values column by column
            values_match = True
            for col in df_parquet.columns:
                pq_col = df_parquet[col]
                csv_col = df_csv[col]
                
                if pq_col.dtype.kind in 'fc':  # float or complex
                    # Numeric comparison with tolerance
                    try:
                        diff = (pq_col - csv_col).abs().max()
                        if pd.isna(diff) or diff > 1e-9:
                            values_match = False
                            break
                    except Exception:
                        # Fallback to string comparison with NaN handling
                        pq_str = pq_col.fillna('').astype(str)
                        csv_str = csv_col.fillna('').astype(str)
                        if not (pq_str == csv_str).all():
                            values_match = False
                            break
                else:
                    # For string/object columns, normalize NaN/NA to empty string before comparison
                    pq_str = pq_col.fillna('').astype(str)
                    csv_str = csv_col.fillna('').astype(str)
                    if not (pq_str == csv_str).all():
                        values_match = False
                        break
            
            checks['values_match'] = values_match
        
        passed = all(checks.values())
        if not passed:
            results['all_passed'] = False
        
        results['tables'].append({
            'table': table_name,
            'passed': passed,
            'checks': checks,
            'parquet_rows': len(df_parquet),
            'csv_rows': len(df_csv)
        })
    
    return results


def export_full_warehouse(
    db_path: str,
    output_dir: str,
    formats: list[str] = None
) -> ExportManifest:
    """
    Export all dbt materialized tables and views (full warehouse dump).
    """
    if formats is None:
        formats = ['parquet', 'csv']
    
    exporter = DeterministicExporter(db_path, output_dir)
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # Get all tables and views in the main schema
    cursor.execute("""
        SELECT name FROM sqlite_master 
        WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' 
        AND name NOT IN ('idx_exposures_dedupe', 'idx_exposures_occurred_at', 'exposures_fixture')
        ORDER BY name
    """)
    tables = [row[0] for row in cursor.fetchall()]
    conn.close()
    
    tables_exported = []
    for table in tables:
        # Skip the seed table
        if table == 'exposures_fixture':
            continue
        result = exporter.export_table(table, formats=formats)
        tables_exported.append(result)
    
    import datetime
    manifest = ExportManifest(
        export_id=hashlib.sha256(
            f"full_warehouse{datetime.datetime.utcnow().isoformat()}".encode()
        ).hexdigest()[:16],
        timestamp=datetime.datetime.utcnow().isoformat() + 'Z',
        experiment_key='*',
        workspace_id='*',
        environment_id='*',
        tables=tables_exported
    )
    
    manifest_path = Path(output_dir) / 'manifest.json'
    with open(manifest_path, 'w') as f:
        json.dump(manifest.to_dict(), f, indent=2, sort_keys=True)
    
    return manifest


if __name__ == "__main__":
    import sys
    
    if len(sys.argv) < 3:
        print("Usage:")
        print("  python -m doppio_export.export <db_path> <output_dir> [experiment_key] [workspace] [environment]")
        print("  python -m doppio_export.export <db_path> <output_dir> --full")
        print("  python -m doppio_export.export --verify <export_dir>")
        sys.exit(1)
    
    if sys.argv[1] == '--verify':
        export_dir = sys.argv[2]
        results = verify_roundtrip(export_dir)
        print(json.dumps(results, indent=2))
        sys.exit(0 if results['all_passed'] else 1)
    
    db_path = sys.argv[1]
    output_dir = sys.argv[2]
    
    if not Path(db_path).exists():
        print(f"Database not found: {db_path}")
        sys.exit(1)
    
    if len(sys.argv) > 3 and sys.argv[3] == '--full':
        manifest = export_full_warehouse(db_path, output_dir)
        print(f"Full warehouse exported: {manifest.export_id}")
        print(f"Tables: {len(manifest.tables)}")
    elif len(sys.argv) > 3:
        experiment_key = sys.argv[3]
        workspace_id = sys.argv[4] if len(sys.argv) > 4 else "default"
        environment_id = sys.argv[5] if len(sys.argv) > 5 else "default"
        
        exporter = DeterministicExporter(db_path, output_dir)
        manifest = exporter.export_experiment(experiment_key, workspace_id, environment_id)
        print(f"Experiment exported: {manifest.export_id}")
        print(f"Tables: {len(manifest.tables)}")
        
        # Run round-trip verification
        exp_dir = Path(output_dir) / f"experiment_{experiment_key}"
        verify_results = verify_roundtrip(str(exp_dir))
        print(f"Round-trip verification: {'PASSED' if verify_results['all_passed'] else 'FAILED'}")
    else:
        print("Experiment key required (or --full)")
        sys.exit(1)