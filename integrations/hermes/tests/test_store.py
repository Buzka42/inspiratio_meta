import sqlite3

import pytest

from illunis_memory.store import (HYPOTHESIS_DEFAULT_DAYS, HYPOTHESIS_MAX_DAYS, MemoryError_, MemoryStore,
                                  TURN_LOG_DAYS, fts_query, iso)

DAY = 86400
T0 = 1_790_000_000


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def store(tmp_path, clock):
    s = MemoryStore(tmp_path / "m" / "memory.db", clock=clock)
    yield s
    s.close()


def test_write_and_newest_recall(store):
    a = store.write(kind="note", text="Prefers evening walks by the river")
    b = store.write(kind="note", text="Drinks green tea after lunch")
    items = store.recall("")
    assert [i["id"] for i in items] == [b["id"], a["id"]]
    assert a["confidence"] == 0.8 and a["expires_at"] is None and a["source"] == "illunis"


def test_db_file_private(tmp_path, clock):
    path = tmp_path / "x" / "memory.db"
    MemoryStore(path, clock=clock).close()
    assert oct(path.stat().st_mode & 0o777) == "0o600"


@pytest.mark.parametrize("kw,msg", [
    ({"kind": "fact", "text": "x"}, "kind"),
    ({"kind": "note", "text": "  "}, "text required"),
    ({"kind": "note", "text": "x" * 1001}, "longer"),
    ({"kind": "note", "text": "x", "confidence": 1.5}, "confidence"),
    ({"kind": "note", "text": "x", "confidence": True}, "confidence"),
    ({"kind": "note", "text": "x", "expires_at": "tomorrow"}, "ISO"),
    ({"kind": "note", "text": "x", "source": ""}, "source"),
])
def test_write_validation(store, kw, msg):
    with pytest.raises(MemoryError_, match=msg):
        store.write(**kw)


def test_fts_recall_ranks_matches_and_ignores_operators(store):
    store.write(kind="note", text="Likes swimming on Saturday mornings")
    store.write(kind="note", text="Allergic reaction to cats was mentioned")
    store.write(kind="note", text="Swimming pool closes early on Sundays; swimming twice a week")
    hits = store.recall("swimming")
    assert len(hits) == 2 and all("wimming" in h["text"] for h in hits)
    assert hits[0]["text"].startswith("Swimming pool")  # more matches ranks first (bm25)
    assert store.recall('swimming" OR text:* NEAR(') != []  # FTS syntax is neutralised
    assert store.recall("nonexistentword") == []
    assert store.recall("!!") == []


def test_fts_diacritics_and_case(store):
    store.write(kind="note", text="Café visits on Fridays")
    assert len(store.recall("CAFE")) == 1


def test_fts_query_builder():
    assert fts_query('a "quoted" NEAR(x) b2') == '"quoted" OR "near" OR "b2"'
    assert fts_query("") == ""


def test_recall_limit_and_kind(store):
    for i in range(12):
        store.write(kind="note", text=f"walk note {i}")
    store.write(kind="hypothesis", text="walk seems to help sleep")
    assert len(store.recall("walk", limit=5)) == 5
    hyp = store.recall("walk", kind="hypothesis")
    assert [h["kind"] for h in hyp] == ["hypothesis"]
    assert len(store.recall("", limit=999)) == 13


def test_hypothesis_default_and_capped_expiry(store):
    h = store.write(kind="hypothesis", text="Sleeps better after walks")
    assert h["expires_at"] == iso(T0 + HYPOTHESIS_DEFAULT_DAYS * DAY)
    far = store.write(kind="hypothesis", text="far", expires_at="2099-01-01T00:00:00Z")
    assert far["expires_at"] == iso(T0 + HYPOTHESIS_MAX_DAYS * DAY)
    with pytest.raises(MemoryError_, match="future"):
        store.write(kind="note", text="past", expires_at="2001-01-01")


def test_expiry_hides_then_purges(store, clock):
    store.write(kind="hypothesis", text="Morning coffee may delay sleep",
                expires_at=iso(T0 + 2 * DAY))
    store.write(kind="note", text="Coffee order is a flat white")
    assert len(store.recall("coffee")) == 2
    clock.t = T0 + 2 * DAY  # expiry is exclusive: at expires_at the item is gone
    assert [i["kind"] for i in store.recall("coffee")] == ["note"]
    assert store.count() == 2
    assert store.purge_expired() == 1
    assert store.count() == 1
    assert len(store.recall("coffee")) == 1  # FTS index stays consistent after delete


def test_forget(store):
    a = store.write(kind="note", text="Daughter's name is private")
    assert store.forget(a["id"]) is True
    assert store.forget(a["id"]) is False
    assert store.recall("daughter") == []
    with pytest.raises(MemoryError_):
        store.forget("'; DROP TABLE memories; --")


def test_forget_scrubs_fts(store):
    a = store.write(kind="note", text="zebracode secret phrase")
    store.forget(a["id"])
    conn = sqlite3.connect(store._path)
    n = conn.execute("SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'zebracode'").fetchone()[0]
    conn.close()
    assert n == 0


def test_turn_log_truncates_and_expires(store, clock):
    store.log_turn("s1", "u" * 1000, "a" * 1000)
    row = sqlite3.connect(store._path).execute("SELECT user_text, assistant_text FROM turn_log").fetchone()
    assert len(row[0]) == 300 and len(row[1]) == 300
    assert store.recall("uuu") == []  # turn log is never recalled
    clock.t = T0 + TURN_LOG_DAYS * DAY
    store.purge_expired()
    assert store.turn_count() == 0


def test_claim_approval_single_use(store):
    assert store.claim_approval("act_12345678", T0 + 60) is True
    assert store.claim_approval("act_12345678", T0 + 60) is False


def test_persists_across_reopen(tmp_path, clock):
    path = tmp_path / "memory.db"
    s = MemoryStore(path, clock=clock)
    s.write(kind="note", text="Persistent marmalade fact")
    s.close()
    s2 = MemoryStore(path, clock=clock)
    assert len(s2.recall("marmalade")) == 1
    s2.close()
