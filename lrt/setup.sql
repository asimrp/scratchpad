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
create function lrt.insert_tuple(numxacts int, sleepsec int) returns int as $$
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
      perform pg_sleep(sleepsec);
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
         raise notice 'no new inserts in lrt.test, nothing to do';
         exit;
      end if;
      increment := increment + (curr_xmin - prev_xmin);
      if increment > numxacts then
         -- Two inserts assuming a 2 segment cluster.  Use negative
         -- values to distinguish inserts from the long running
         -- transaction.
         insert into lrt.test values (-cnt, 0), (-cnt-1, 0);
         cnt := cnt + 2;
         increment := 0;
      end if;
      prev_xmin := curr_xmin;
      -- Wait for new inserts.
      perform pg_sleep(sleepsec);
   end loop;

   return cnt - 1;
end;
$$ language plpgsql;

create table lrt.my_tab (a int) distributed by (a);
insert into lrt.my_tab values (1);

-- Function to have a long running transaction active without being
-- terminated due to idle timeout.  To terminate the loop, insert a
-- value greater that the input parameter into my_tab.
create function lrt.my_func(int) returns int as $$
declare
   flag int;
begin
   loop
      select max(a) into flag from lrt.my_tab;
      if flag > $1 then
         exit;
      end if;
      perform count(*) from lrt.my_tab;
      perform pg_sleep(20);
   end loop;
   return flag;
end;
$$ language plpgsql;
