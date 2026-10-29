import json
from contextlib import closing
from pathlib import Path
import random
import sqlite3
import unittest

SQL = (Path(__file__).parent / 'funnel_fixture.sql').read_text(encoding='utf-8')
STEPS = ['view_item', 'add_to_cart', 'begin_checkout', 'purchase']


def session_key(user, sid):
    return json.dumps([user, sid], separators=(',', ':')) if user and sid and sid > 0 else None


def sql_funnel(rows, strict=True):
    with closing(sqlite3.connect(':memory:')) as con:
        con.execute('CREATE TABLE events(session_key TEXT, ts INTEGER, event_name TEXT)')
        con.executemany('INSERT INTO events VALUES(?,?,?)', rows)
        result = con.execute(SQL, {'strict_order': int(strict)}).fetchall()
    return {row[0]: row[1:] for row in result}


def reference(events, strict=True):
    found = []
    previous = None
    for i, step in enumerate(STEPS):
        candidates = [t for t, name in events if name == step and
                      (i == 0 or (previous is not None and (t > previous if strict else t >= previous)))]
        previous = min(candidates) if candidates else None
        found.append(previous)
    return tuple(found)


def canonical_orders(rows):
    # Explicitly independent reference for transaction quarantine and dedup policy.
    grouped = {}
    for transaction, user, amount, ts in rows:
        if transaction is not None:
            grouped.setdefault(transaction, []).append((user, amount, ts))
    out = {}
    for transaction, events in grouped.items():
        users = {u for u, a, t in events if u is not None}
        amounts = {round(a, 2) for u, a, t in events if a is not None}
        if len(users) > 1 or len(amounts) > 1 or any(a is not None and a < 0 for u, a, t in events):
            continue
        out[transaction] = min(events, key=lambda row: (row[2], row[0] or '', row[1] if row[1] is not None else float('-inf')))
    return out


class FunnelTests(unittest.TestCase):
    def test_normal_ordered_path(self):
        rows = [('s', i*10, name) for i, name in enumerate(STEPS, 1)]
        self.assertEqual(sql_funnel(rows)['s'], (10,20,30,40))

    def test_earlier_invalid_cart_does_not_hide_later_valid_cart(self):
        rows = [('s',5,'add_to_cart'),('s',10,'view_item'),('s',20,'add_to_cart'),('s',30,'begin_checkout'),('s',40,'purchase')]
        self.assertEqual(sql_funnel(rows)['s'], (10,20,30,40))

    def test_purchase_without_steps_is_not_funnel_completion(self):
        self.assertEqual(sql_funnel([('s',10,'purchase')])['s'], (None,None,None,None))

    def test_duplicate_events_do_not_duplicate_sessions(self):
        rows = [('s',i,name) for i,name in enumerate(STEPS)]*3
        out = sql_funnel(rows)
        self.assertEqual(len(out),1)
        self.assertEqual(out['s'], (0,1,2,3))

    def test_sessions_of_same_user_are_not_stitched(self):
        a,b = session_key('u',1),session_key('u',2)
        out = sql_funnel([(a,10,'view_item'),(a,20,'add_to_cart'),(b,30,'begin_checkout'),(b,40,'purchase')])
        self.assertIsNone(out[a][-1])
        self.assertIsNone(out[b][-1])

    def test_session_id_is_not_globally_unique(self):
        a,b = session_key('u1',42),session_key('u2',42)
        self.assertNotEqual(a,b)
        out = sql_funnel([(a,10,'view_item'),(a,20,'add_to_cart'),(b,30,'begin_checkout'),(b,40,'purchase')])
        self.assertTrue(all(row[-1] is None for row in out.values()))

    def test_equal_timestamps_are_an_explicit_sensitivity(self):
        rows = [('s',10,name) for name in STEPS]
        self.assertEqual(sql_funnel(rows,True)['s'],(10,None,None,None))
        self.assertEqual(sql_funnel(rows,False)['s'],(10,10,10,10))

    def test_invalid_identity_excluded(self):
        self.assertIsNone(session_key('',1))
        self.assertIsNone(session_key('u',0))
        self.assertEqual(sql_funnel([(None,10,'view_item')]),{})

    def test_same_transaction_is_one_order(self):
        out = canonical_orders([('o','u',100,10),('o','u',100,20)])
        self.assertEqual(len(out),1)
        self.assertEqual(sum(v[1] for v in out.values()),100)

    def test_conflicting_transaction_is_quarantined(self):
        self.assertEqual(canonical_orders([('o','u',100,10),('o','u',120,20)]),{})
        self.assertEqual(canonical_orders([('o','u1',100,10),('o','u2',100,20)]),{})

    def test_missing_amount_is_not_zero(self):
        self.assertIsNone(canonical_orders([('o','u',None,10)])['o'][1])
        self.assertEqual(canonical_orders([(None,'u',100,10)]),{})

    def test_boundary_buffer_policy(self):
        def eligible(days):
            return '2020-11-02' <= min(days) <= '2021-01-30' and not {'2020-11-01','2021-01-31'}.intersection(days)
        self.assertFalse(eligible(['2020-11-01','2020-11-02']))
        self.assertFalse(eligible(['2021-01-30','2021-01-31']))
        self.assertTrue(eligible(['2020-12-31','2021-01-01']))

    def test_randomized_sql_against_independent_reference(self):
        rng = random.Random(42)
        streams = {f's{i}': [(rng.randrange(0,30),rng.choice(STEPS+['page_view'])) for _ in range(rng.randrange(1,45))] for i in range(500)}
        rows = [(key,ts,name) for key, events in streams.items() for ts,name in events]
        for strict in [True,False]:
            out = sql_funnel(rows,strict)
            for key, events in streams.items():
                self.assertEqual(out[key],reference(events,strict))
            for key, row in out.items():
                flags = [v is not None for v in row]
                self.assertEqual(flags,sorted(flags,reverse=True))


if __name__ == '__main__':
    unittest.main(verbosity=2)
