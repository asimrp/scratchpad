# LRT = Long Running Transactions in Greenplum database

Greenplum database behaves in a peculiar way when bombarded with a
large number of short transactions along with one or more concurrent
long running transactions.  This is a collection of scripts to
simulate this kind of workload.  The scripts currently assume a 1
master and 2 segments cluster.  However, they may be easily extended
to arbitrary cluster configuration.

## Background
In presence of such mixed operational and analytics workload,
Greenplum database is seen to spend more time doing visibility checks.
Particulary, checking the status of distributed XID in distributed
transaction log.  Distributed transaction log is very similar to
PostgreSQL commit log (clog).  The only difference is each entry in
distributed transaction log is 8 bytes to accommodate one distributed
XID.  Each segment along with master maintains a distributed
transaction log.  The location of a distributed xid, identified by
page and offset within a page, is determined using local xid.

Distributed transaction log is, roughly speaking, used like this for
visibility: For each local xid (xmin/xmax), identify the location in
distributed transaction log, read 8 bytes from that location and see
if they represent a valid distributed xid.  If they do, the
distributed transaction was committed.  If they don't then the local
xid was not part of a distributed transaction and it's clog status is
checked.

## Objective

The scripts in this repo demonstrate effectiveness of backend-local
distributed XID cache, that is used on top of SLRU (shared memory)
page cache.

## How to use the scripts

* Create a Greenplum cluster with 1 master and 2 segments, with or
  without mirrors.

* Disable local distributed xid cache:

```
gpconfig -c gp_max_local_distributed_cache -v 0
gpstop -air
psql -d postgres -c 'show gp_max_local_distributed_cache'
```

* Start long running transaction.

```
psql -d postgres -f long_running_xact.sql &
```

* Generate sql files for single transaction insert and delete
  workload.  One page of BLCKSZ=32768 bytes in distributed transaction
  log accommodates 4096 entries.  Each insert / delete statement would
  cause a new entry to be created.  To speed up filling of distributed
  transaction log, we can interleave 4095 selects within each insert /
  delete.  Every insert / delete would fall on a different page and
  cause a new slot to be used in SLRU page cache.  The total number of
  pages to be filled is determined by the counts in the outer for
  loops below.

```
echo "set search_path=lrt,public;" > insert_test.sql
for i in $(seq 1 128);
do
    # Insert two values, one per segment.
    echo "insert into test values ($i, $i), ($[i+1], $[i+1]);" >> insert_test.sql;
    for entry in $(seq 1 4095);
    do
        # Consume one xid on each segment.
        echo "select 1 from gp_dist_random('gp_id');" >> insert_test.sql;
    done
done
echo "set search_path=lrt,public;" > delete_test.sql
for i in $(seq 1 128);
do
    echo "delete from test where a = $i or a = $[i+1];" >> delete_test.sql;
    for entry in $(seq 1 4095);
    do
        # Consume one xid on each segment.
        echo "select 1 from gp_dist_random('gp_id');" >> delete_test.sql;
    done
done
```

* Start a workload of singleton inserts, deletes and a long running
  transaction that periodically inserts.  Replace "postgres" in the
  following commands with another database, if necessary.

```
sed -ie 's/%db%/postgres/' long_running_insert.sql
psql -d postgres -f long_running_insert.sql > /tmp/long_running_insert.out &&
 psql -d postgres -f delete_test.sql > /tmp/delete_test.out &
```

* Wait for the above command to finish.

* Terminate the long running transaction.

```
psql -d postgres -c 'insert into my_tab values (100)'
```