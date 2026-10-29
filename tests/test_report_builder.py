import csv
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('report_builder', ROOT/'scripts/build_report.py')
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
STRICT=ROOT/'tests/fixtures/strict'
WEAK=ROOT/'tests/fixtures/weak'


class ReportTests(unittest.TestCase):
    def test_fixture_report_is_clearly_watermarked(self):
        with tempfile.TemporaryDirectory() as d:
            result=mod.build(STRICT,Path(d),'fixture',WEAK)
            self.assertEqual(result['funnel_counts'],[1000,500,250,100])
            self.assertEqual(result['weak_counts'],[1000,520,275,120])
            self.assertIn('KHÔNG PHẢI KẾT QUẢ GA4',(Path(d)/'bao_cao.md').read_text(encoding='utf-8'))
            self.assertIn('KHÔNG PHẢI KẾT QUẢ GA4',(Path(d)/'funnel.svg').read_text(encoding='utf-8'))

    def test_source_requires_job_id(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError,'job-id'):
                mod.build(STRICT,Path(d),'source')

    def test_rejects_nonmonotonic_counts(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d)/'strict'
            shutil.copytree(STRICT,folder)
            path=folder/'08_funnel_steps.csv'
            with path.open(encoding='utf-8',newline='') as f:
                rows=list(csv.DictReader(f))
            rows[2]['sessions']='600'
            with path.open('w',encoding='utf-8',newline='') as f:
                writer=csv.DictWriter(f,fieldnames=rows[0].keys())
                writer.writeheader();writer.writerows(rows)
            with self.assertRaisesRegex(ValueError,'increase'):
                mod.load(folder)

    def test_rejects_mismatching_exported_ratio(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d)/'strict'
            shutil.copytree(STRICT,folder)
            p=folder/'07_kpi_overview.csv'
            p.write_text('eligible_sessions,strict_funnel_purchase_sessions,view_to_purchase_rate\n2000,100,0.8\n',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'overview conversion'):
                mod.load(folder)

    def test_weak_order_cannot_reduce_count(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError,'counts >= strict'):
                mod.build(WEAK,Path(d),'fixture',STRICT)


if __name__ == '__main__':
    unittest.main(verbosity=2)
