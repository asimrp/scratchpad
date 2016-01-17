# Mixed workload simulation for Greenplum database

Greenplum database behaves in a peculiar way when bombarded with a
large number of short DML/DDL transactions in presence of one or more
long running transactions (LRT).  This collection of scripts aims to
simulate such workload.  The scripts currently assume a Greenplum
cluster of 1 master and 2 segments.  They may be easily extended to
arbitrary cluster configuration.

## Background

In presence of such mixed operational and analytics workload,
performance of sequential scan of heap tables is seen to degrade in
Greenplum.  Profile results indicate visibility checks as the top
bottleneck.  Drilling further down, checking status of distributed XID
in distributed transaction log takes significantly longer in presence
of LRT.  Distributed transaction log is very similar to PostgreSQL
commit log (clog).  E.g. as in case of clog, SLRU page cache is used
to read distributed transaction log.  One difference being each entry
in distributed transaction log is 8 bytes.  A distributed transaction
identifier is two sets of 32-bit integers.  Each segment along with
master maintains a distributed transaction log.  Location of a
distributed xid, identified by page and offset within a page, is
determined using local xid (xmin/xmax found in heap tuples).  During
sequntial scan, for each xmin and xmax, corresponding entry in
distributed transaction log is read.  If it represents a valid
distributed transaction, the corresponding xmin/xmax is considered
committed.  If the entry in distributed transaction log is invalid,
clog is consulted to determine status of the xmin/xmax.  Note: this is
a very simple and inaccurate description of visibility checks.  For
the gory details, don't hesitate looking at `tqual.c:XidInSnapshot()`
function.

## Objective

The scripts demonstrate effectiveness of backend-local distributed XID
cache, that is used on top of SLRU (shared memory) page cache.

## How to use the scripts

* Determine how many distributed transaction log pages you want to
  generate.  Typically, this number should be significanly bigger than
  the size of SLRU page cache, which currently is 8 pages.  On my MAC,
  value of 128 produces tangible results.  Then determine size of
  local cache of distributed transactions.  Greenplum default is 1024.
  In order to determine effectiveness of this cache, at least two runs
  of `start.sh` are necessary.  One run with the cache disabled
  (`cache_size = 0`) and another with a greater value.  To start the
  simulation, run `./start.sh <num_pages> <cache_size>`.  E.g.

```
./start.sh 512 0 && ./start.sh 512 1024 && ./start.sh 512 2048
```

* It may take several minutes or hours to run, so be ready with a huge
  cup of tea / coffee.  The time per run of `start.sh` is directly
  proportional to `num_pages` parameter.

* Each run of `start.sh` generates one output file containing
  sequential scan times.  This file is named as
  `seqscan_pages<num_pages>_cache<cache_size>.out`.

* The script leaves system with one read LRT active.  You may inspect the
  system in this state, to further validate the results.  To terminate
  the LRT, run

```
psql -d postgres -c 'insert into lrt.my_tab values (11);'
```
