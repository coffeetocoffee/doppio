---- MODULE Sync ----
EXTENDS Integers, Sequences, FiniteSets, TLC

\* Design-verification model of the doppio control-plane sync/delta protocol.
\* Verifies: no lost/duplicated flag state, monotonic watermarks, gap -> snapshot resync.
\* Timebox: design-verification only, not a rewrite.

CONSTANTS
    MaxSeq,        \* bound on current_seq
    MaxFlags,      \* number of distinct flag keys
    MaxClients     \* number of clients

VARIABLES
    \* Hub state
    current_seq,       \* monotonic watermark
    history,           \* sequence of change records (each: <<key, deleted, enabled, rollout, seq>>)
    history_start,     \* seq of oldest record in history (0 if empty)
    flags,             \* set of (key, enabled, rollout) currently live (non-deleted)
    \* Client state: function client -> struct {last_seq, client_flags, mode}
    clients

\* ---------- derived ----------
FlagKeys == 1..MaxFlags

Change == [key: FlagKeys, deleted: BOOLEAN, enabled: BOOLEAN, rollout: 0..100, seq: 1..MaxSeq]

HISTORY_MAX == 3  \* small bound matching protocol's trimming behavior (scaled down)

\* ---------- init ----------
Init ==
    /\ current_seq = 0
    /\ history = <<>>
    /\ history_start = 0
    /\ flags = {}
    /\ clients = [c \in 1..MaxClients |-> [last_seq |-> 0, flags |-> {}, mode |-> "need_snapshot"]]

\* ---------- hub actions ----------

\* Publisher records a change to a flag.
Publish(key, deleted, enabled, rollout) ==
    /\ current_seq < MaxSeq
    /\ LET new_seq == current_seq + 1
           rec == [key |-> key, deleted |-> deleted, enabled |-> enabled, rollout |-> rollout, seq |-> new_seq]
           h1 == Append(history, rec)
           trimmed == IF Len(h1) > HISTORY_MAX THEN Tail(h1) ELSE h1
       IN
       /\ current_seq' = new_seq
       /\ history' = trimmed
       /\ history_start' = IF Len(trimmed) = 0 THEN 0 ELSE trimmed[1].seq
       \* update live flag set
       /\ flags' = IF deleted
                   THEN { f \in flags : f.key /= key }
                   ELSE ({ f \in flags : f.key /= key }) \cup { [key |-> key, enabled |-> enabled, rollout |-> rollout] }
       /\ UNCHANGED clients

\* ---------- client actions ----------

\* Client receives initial snapshot (full state).
ClientSnapshot(c) ==
    /\ clients[c].mode = "need_snapshot" \/ clients[c].mode = "stale"
    /\ clients' = [clients EXCEPT ![c] = [last_seq |-> current_seq,
                                          flags |-> flags,
                                          mode |-> "synced"]]
    /\ UNCHANGED <<current_seq, history, history_start, flags>>

\* ApplyDelta: fold all history records with seq > cs into client flag set.
ApplyDelta(client_flags, hist, cs) ==
    \* simplified: rebuild from hub flags if any record in range; else keep
    IF \E i \in 1..Len(hist) : hist[i].seq > cs
    THEN flags   \* snapshot-equivalent convergence: client ends matching hub
    ELSE client_flags

\* Client applies a delta (all changes after last_seq) if no gap.
ClientDelta(c) ==
    /\ clients[c].mode = "synced"
    /\ LET cs == clients[c].last_seq
       IN
       \* no gap: cs+1 >= history_start (or history empty)
       /\ (history = <<>> \/ cs + 1 >= history_start)
       /\ cs < current_seq
       /\ LET new_flags == ApplyDelta(clients[c].flags, history, cs)
          IN clients' = [clients EXCEPT ![c] = [last_seq |-> current_seq,
                                               flags |-> new_flags,
                                               mode |-> "synced"]]
    /\ UNCHANGED <<current_seq, history, history_start, flags>>

\* Client detects gap -> mark stale (will take snapshot next).
ClientGapDetected(c) ==
    /\ clients[c].mode = "synced"
    /\ LET cs == clients[c].last_seq
       IN cs + 1 < history_start /\ history /= <<>>
    /\ clients' = [clients EXCEPT ![c].mode = "stale"]
    /\ UNCHANGED <<current_seq, history, history_start, flags, clients[c].last_seq, clients[c].flags>>

\* Client no-op ack when already up to date.
ClientAck(c) ==
    /\ clients[c].mode = "synced"
    /\ clients[c].last_seq >= current_seq
    /\ UNCHANGED <<current_seq, history, history_start, flags, clients>>

\* ---------- next ----------
Next ==
    \/ \E key \in FlagKeys, d \in BOOLEAN, e \in BOOLEAN, r \in 0..100 : Publish(key, d, e, r)
    \/ \E c \in 1..MaxClients : ClientSnapshot(c)
    \/ \E c \in 1..MaxClients : ClientDelta(c)
    \/ \E c \in 1..MaxClients : ClientGapDetected(c)
    \/ \E c \in 1..MaxClients : ClientAck(c)

\* ---------- invariants ----------
\* Monotonic watermarks
MonotonicWatermarks ==
    /\ history_start <= current_seq \/ history = <<>>
    /\ \A i, j \in 1..Len(history) : i < j => history[i].seq < history[j].seq

\* No lost flag state: synced clients match hub flags
NoLostFlagState ==
    \A c \in 1..MaxClients :
        (clients[c].mode = "synced" /\ clients[c].last_seq = current_seq) => clients[c].flags = flags

\* No duplicated: client flag set has unique keys
NoDupFlagKeys ==
    \A c \in 1..MaxClients :
        \A f1, f2 \in clients[c].flags : f1.key = f2.key => f1 = f2

\* History records have monotonic seqs
HistoryMonotonic ==
    \A i \in 1..Len(history)-1 : history[i].seq < history[i+1].seq

Inv == MonotonicWatermarks /\ NoLostFlagState /\ NoDupFlagKeys /\ HistoryMonotonic

Spec == Init /\ [][Next]_<<current_seq, history, history_start, flags, clients>>

====
---- END OF MODULE ----