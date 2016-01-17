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

* If required, edit `start.sh` and change `NUM_PAGES`.  This value is
  the number of distributed transaction log pages that iterations of
  insert and delete transactions will generate.  Increasing this value
  will increase the difference between scan times of with and without
  local cache.

* Start the run:

```
./start.sh
```

* It may take several minutes or hours to run, depending on how
  powerful the hardware is and `NUM_PAGES` parameter.

* Once the script has finished, it should have generated two output
  files in its current directory, containing sequential scan times
  with and without cache.  The files are named as `seqscan_*.out`.

* The script leaves system with local distributed cache set to 1024
  and a long running read transaction active.  You may inspect the
  system in this state, to further validate the results.  To terminate
  the long running transaction, execute the following command.

```
psql -d postgres -c 'insert into lrt.my_tab values (11);'
```
