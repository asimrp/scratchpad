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

Distributed transaction log is roughly used like this for visibility:
For each local xid (xmin/xmax), identify the location in distributed
transaction log, read 8 bytes from that location and see if they
represent a valid distributed xid.  If they do, the distributed
transaction was committed.  If they don't then the local xid was not
part of a distributed transaction and it's clog status is checked.

## Objective

The scripts in this repo demonstrate effectiveness of backend-local
distributed XID cache, that is used on top of shared SLRU page cache.

## How to use the scripts

* Create a Greenplum cluster with 1 master and 2 segments, with or
  without mirrors.

* Disable local distributed xid cache:

```
gpconfig -c gp_max_local_distributed_cache -v 0
gpstop -air
psql -d postgres -c 'show gp_max_local_distributed_cache'
```

* Start long running transaction

```
psql -d postgres -f long_running_xact.sql
```

* Generate sql files for single transaction insert and delete
  workload.  Each insert / delete statement would cause a new
  distributed transaction log entry to be created.  The count of
  inserts and deletes will affect total run time of the test.

```
echo "\timing on" > insert_test.sql
for i in $(seq 1 $[4096 * 16 * 2]);
do
    echo "insert into test values ($i, $i);" >> insert_test.sql;
done
echo "\timing on" > delete_test.sql
for i in $(seq 1 $[4096 * 2]);
do
    echo "delete from test where a = $i;" >> delete_test.sql;
done
```

* Start a select workload, causing local xid to grow faster.  Consequently,
  distributed transaction log grows faster on disk.  This helps
  spread out insert and delete xids across multiple pages of distributed
  transaction log.

```
for i in $(seq 1 4096);
do
    echo "select 1 from gp_dist_random('gp_id');" >> bump_xid.sql;
done
while true;
do
    psql -d postgres -f bump_xid.sql > /tmp/bump_xid2.out;
    sleep 10;
done &
```

* Start a workload of singleton inserts, deletes.  Replace "postgres"
  in the following commands with another database, if necessary.

```
sed -ie 's/%db%/postgres/' long_running_insert.sql
psql -d postgres -f long_running_insert.sql > /tmp/long_running_insert.out &&
 PGOPTIONS='-c search_path=lrt,public' psql -d postgres -f delete_test.sql > /tmp/delete_test.out &
```

* Wait for the above command to finish.

* Kill the background job running select statements.

* Terminate the long running transaction.

```
psql -d postgres -c 'insert into my_tab values (100)'
```