#!/bin/bash

USAGE="start.sh <num_pages> <cache_size>"
if [ $# -ne 2 ]; then
    echo $USAGE
    exit 1
fi

# Higher this value, large is the scan time difference between with
# and without local xid cache.
NUM_PAGES=$1
if [ $NUM_PAGES -le 0 ]; then
    echo "invalid value for num_pages"
    exit 1
fi

# Local distributed cache size, in number of entries.
CACHE_SIZE=$2
if [ $CACHE_SIZE -lt 0 ]; then
    echo "invalid value for cache_size"
    exit 1
fi

# Generates insert_one_page.sql, delete_one_page.sql and
# seqscan.sql in current directory.
generate_data()
{
    # One run of insert_one_page.sql will insert one tuple and consume
    # xids using select so that one page of distributed transaction log is
    # covered.
    echo "set search_path=lrt,public;" > insert_one_page.sql
    # Insert two values, one per segment.
    echo "insert into test values (1, 1), (2, 2);" >> insert_one_page.sql
    # One insert/delete transaction consumes two xids, one for the
    # insert and one for 2pc.  We therefore need 4092 selects and 2
    # inserts to cover 1 page of 4096 transactions.
    for i in $(seq 1 4092);
    do
	# Consume one xid on each segment.
	echo "select 1 from gp_dist_random('gp_id');" >> insert_one_page.sql;
    done
    echo "insert into test values (1, 1), (2, 2);" >> insert_one_page.sql

    echo "set search_path=lrt,public;" > delete_one_page.sql
    echo "delete from test where a=1 or a=2;" >> delete_one_page.sql
    for i in $(seq 1 4094);
    do
	# Consume one xid on each segment.
	echo "select 1 from gp_dist_random('gp_id');" >> delete_one_page.sql;
    done

    # Select statements to measure sequential scan times.
    echo "\timing on" > seqscan.sql
    for i in $(seq 1 50);
    do
	echo "select count(*) from lrt.test;" >> seqscan.sql;
    done
}

# One argument: bytes - value of cache.  To disable, pass 0.
set_local_cache()
{
    bytes=$1
    gpconfig -c gp_max_local_distributed_cache -v $bytes
    gpstop -air
    if [ $? -ne 0 ]; then
	echo "cannot stop GPDB"
	exit 1
    fi
    cache=$(psql -t -d postgres -c 'show gp_max_local_distributed_cache;')
    if [ $cache -ne $bytes ]; then
	echo "failed to set gp_max_local_distributed_cache to $bytes"
	exit 1
    fi
}

# Start long running transactions
setup_transactions()
{
    psql -d postgres -f setup.sql
    echo '\d lrt.* \\ \df lrt.*' | psql -d postgres

    echo "Starting long running read transaction"
    psql -d postgres -f long_running_xact.sql > /tmp/long_running_xact.out &
    jobs -l

    echo "Advancing distributed transaction log by one page"
    psql -d postgres -f insert_one_page.sql > /tmp/insert_one_page.out

    echo "Starting long running insert"
    psql -d postgres -f long_running_insert.sql > /tmp/long_running_insert1.out &
    jobs -l

    echo "Advancing distributed transaction log by one page"
    psql -d postgres -f insert_one_page.sql > /tmp/insert_one_page.out

    # Xid of this transaction falls on a farther page as compared to
    # previous long running insert.
    echo "Starting another long running insert"
    psql -d postgres -f long_running_insert.sql > /tmp/long_running_insert1.out &
    jobs -l
}

# Initiate singleton inserts and deletes.
#
# One argument: num_pages - number of distributed transaction log
# pages to generate.
start_workload()
{
    num_pages=$1
    # Loop to insert one tuple per transaction to build up distributed
    # transaction log.
    echo "Initiating singleton inserts to advance distributed transaction log"
    for i in $(seq 3 $num_pages);
    do
	echo "page $i"
	sed -e "s/(1, 1)/($i, $i)/" -e "s/(2, 2)/($[i+1], $[i+1])/" insert_one_page.sql > insert_next_page.sql
	psql -d postgres -f insert_next_page.sql > /tmp/insert_one_page$i.out
    done

    echo "Waiting for long running inserts to terminate..."
    wait %2 # first long running insert
    wait %3 # second long running insert
    jobs -l # should only report %1 - long running read

    echo "Initiating singleton deletes"
    for i in $(seq 3 $num_pages);
    do
	echo "page $i"
	sed -e "s/a=1/a=$i/" -e "s/a=2/a=$[i+1]/" delete_one_page.sql > delete_next_page.sql
	psql -d postgres -f delete_next_page.sql > /tmp/delete_one_page$i.out
    done
}

stop_long_running_read()
{
    psql -d postgres -c 'insert into lrt.my_tab values (11);'
    wait %1
    jobs -l
    echo "Stopped long running read transaction"
}

###########################
# Main routine starts here

generate_data

# Enable local xid cache. 1024 is default value in production.
set_local_cache $CACHE_SIZE
echo "*** Local xid cache set to $CACHE_SIZE ***"
setup_transactions
start_workload $NUM_PAGES

# Sequential scan of lrt.test hereafter, while the long running read
# transaction is still running, should cause two slots in SLRU
# occupied by the two long running insert transactions.  If local
# distributed xid cache is enabled, it should enhance performance by
# avoiding reading of the same distributed transaction log pages
# multiple times due to miss in SLRU.
echo "Measuring sequential scan time for lrt.test"
name=seqscan_pages${NUM_PAGES}_cache${CACHE_SIZE}
psql -d postgres -f seqscan.sql > ${name}.out
grep Time: ${name}.out | awk '{print $2}' > /tmp/scantimes.txt
echo "drop table if exists ${name};
 create table ${name} (ms numeric) distributed by (ms);
 copy ${name} from '/tmp/scantimes.txt';" | psql -d postgres
echo "Scan times recorded in table ${name} in postgres database."
echo "To stop long running read, run the following:"
echo "    psql -d postgres -c 'insert into lrt.my_tab values (11)'"
