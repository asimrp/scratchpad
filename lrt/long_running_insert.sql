-- Start long running transaction that inserts periodically.  SLRU
-- cache can hold upto 8 pages.  Each page contains 4096 transactions.
-- We want the long running transaction to insert one tuple into
-- lrt.test after every 8 distributed transaction log pages.  The
-- second argument is number of seconds to wait for new inserts from
-- other transactions.  If this is too long, we will end up producing
-- less out-of-order transaction log reads during sequential scan of
-- lrt.test.

begin;
\timing on
select lrt.insert_tuple(32768, 10);
end;
