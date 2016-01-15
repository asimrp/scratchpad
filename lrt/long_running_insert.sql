drop schema if exists lrt cascade;
create schema lrt;
create table lrt.test(a int, b int) distributed by (a);

-- This function should be invoked within a begin/end block.  It
-- inserts one tuple per segment into a table at specific intervals,
-- measured in number of transactions.  It assumes that another
-- session is inserting one tuple per transaction into the same table.
-- numxacts defines the number of tuples (or xacts) that must be
-- inserted by other session(s) before this function inserts a new
-- tuple.  By carefully choosing numxacts, specific layout of xmin
-- values can be achieved in the table.  A scan of the table
-- afterwards would necessitate out-of-order reading of distributed
-- transaction log so that local distributed xid cache, if enabled,
-- will have a hit but shared SLRU cache would have a miss for the
-- some transactions.
--
-- The function terminates when table lrt.test receives no new tuple
-- during the sleep.  Return value is total number of tuples inserted.
create function lrt.insert_tuple(numxacts int) returns int as $$
declare
   prev_xmin int;
   curr_xmin int;
   increment int;
   cnt int;
begin
   -- Check if the table is empty.  The loop ahead should only be
   -- entered when the table has at least one tuple.
   select count(*) into cnt from lrt.test where gp_segment_id = 0;
   if cnt = 0 then
      perform pg_sleep(5);
      select count(*) into cnt from lrt.test where gp_segment_id = 0;
      if cnt = 0 then
         raise notice 'table lrt.test remained empty on seg0, nothing to do';
	 return 0;
      end if;
   end if;

   prev_xmin := 0;
   cnt := 1;
   increment := 0;
   loop
      -- xmin may differ across segments, always read from the same
      -- segment.
      select max(int4in(xidout(xmin))) into curr_xmin from lrt.test
         where gp_segment_id = 0;
      if curr_xmin = prev_xmin then
         raise notice 'no new inserts in lrt.test, nothing to do'
         exit;
      end if;
      increment := increment + (curr_xmin - prev_xmin);
      if increment > numxacts then
         -- two inserts assuming a 2 segment cluster
         insert into lrt.test values (-cnt, 0);
         insert into lrt.test values (-cnt-1, 0);
         cnt := cnt + 2;
         increment := 0;
      end if;
      prev_xmin := curr_xmin;
      -- wait 5 seconds for new inserts
      perform pg_sleep(5);
   end loop;

   return cnt - 1;
end;
$$ language plpgsql;

-- Start a long running insert session to insert one tuple per
-- transaction, in background.  Tuples are inserted in order starting
-- from a=1.
\! PGDATABASE=%db% PGOPTIONS='-c search_path=lrt,public' psql -f insert_test.sql > /tmp/insert.out &

-- Start long running transaction that inserts periodically ...
begin;
\timing on
-- Our objective is to simulate the case when the page containing
-- distributed xid is evicted from SLRU page cache but is present in
-- local cache.  The long running transaction should insert a new
-- tuple after every 8 * xacts-per-page transactions.  xacts-per-page
-- is defined in distributedlog.c to be
--
--    BLCKSZ / sizeof(DistributedLogEntry)
--
select lrt.insert_tuple(32768);
end;
