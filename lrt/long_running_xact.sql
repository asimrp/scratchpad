-- Start long running transaction ...
begin;
\timing on
select lrt.my_func(10);
end;
