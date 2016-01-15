 drop table if exists my_tab;
 create table my_tab (a int) distributed by (a);
 insert into my_tab values (1);

-- Function to have a long running transaction active without being
-- terminated due to idle timeout.  To terminate the loop, insert a
-- value greater that the input parameter into my_tab.
 drop function if exists my_func(int);
 create function my_func(int) returns int as $$
 declare
    flag int;
 begin
    loop
       select max(a) into flag from my_tab;
       if flag > $1 then
          exit;
       end if;
       perform count(*) from my_tab;
       perform pg_sleep(20);
    end loop;
    return flag;
 end;
 $$ language plpgsql;

-- Start long running transaction ...
 begin;
 \timing on
 select my_func(10);
 end;
